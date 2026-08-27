import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'secure_secret_store.dart';

class TelegramService {
  final ActionHandler _actionHandler;
  final AiService _aiService;

  static const int _maxBackoffSeconds = 60;

  String _botToken = '';
  bool _isEnabled = false;
  int _lastUpdateId = 0;
  bool _isPolling = false;
  Timer? _pollingTimer;
  int _consecutiveFailures = 0;
  // P1-3 audit fix: manage shared http client to cancel pending long polls
  http.Client? _httpClient;

  TelegramService(this._actionHandler, this._aiService);

  String get botToken => _botToken;
  bool get isEnabled => _isEnabled;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = await SecureSecretStore.readAndMigrate(
          secureKey: 'secure_telegram_bot_token',
          legacyPrefsKey: 'telegram_bot_token',
        ) ??
        '';
    _isEnabled = prefs.getBool('telegram_enabled') ?? false;

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    }
  }

  Future<void> saveSettings({required String botToken, required bool isEnabled}) async {
    _botToken = botToken;
    _isEnabled = isEnabled;
    final prefs = await SharedPreferences.getInstance();
    await SecureSecretStore.write('secure_telegram_bot_token', _botToken);
    await prefs.setBool('telegram_enabled', _isEnabled);

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    } else {
      stopPolling();
    }
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _httpClient = http.Client();
    _pollUpdates();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
    _httpClient?.close();
    _httpClient = null;
  }

  Future<void> _pollUpdates() async {
    if (!_isPolling || _botToken.isEmpty) return;

    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/getUpdates');
      final client = _httpClient ?? http.Client();
      final response = await client.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'offset': _lastUpdateId + 1,
          'timeout': 30, // Long polling timeout
          'allowed_updates': ['message'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final results = data['result'] as List;
          for (final update in results) {
            _lastUpdateId = update['update_id'];
            if (update['message'] != null && update['message']['text'] != null) {
              final text = update['message']['text'];
              final chatId = update['message']['chat']['id'];

              // Process message asynchronously so we don't block the polling loop
              _handleIncomingMessage(chatId.toString(), text);
            }
          }
        }
        _consecutiveFailures = 0;
      } else {
        _consecutiveFailures++;
        if (kDebugMode) {
          print('Telegram polling error: HTTP ${response.statusCode}');
        }
      }
    } catch (e) {
      _consecutiveFailures++;
      // Never log the exception itself: http's ClientException commonly
      // embeds the request URI, which contains the bot token.
      if (kDebugMode) {
        print('Telegram polling error: ${e.runtimeType}');
      }
    }

    // Continue polling. A failing request (bad token, no connectivity) skips
    // the API's own 30s long-poll hold, so without backoff this would retry
    // once a second indefinitely - back off exponentially on failure instead.
    if (_isPolling) {
      final delaySeconds = _consecutiveFailures == 0
          ? 1
          : min(1 << _consecutiveFailures, _maxBackoffSeconds);
      _pollingTimer = Timer(Duration(seconds: delaySeconds), _pollUpdates);
    }
  }

  Future<void> _handleIncomingMessage(String chatId, String text) async {
    // Acknowledge receipt
    await _sendMessage(chatId, '🤖 Received: "$text". Working on it...');

    try {
      // 1. Send text to AI
      final aiResponse = await _aiService.sendMessage(text);
      
      // 2. Parse the action
      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        // 3. Execute the action
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) {
            // Send progress updates back to telegram
            _sendMessage(chatId, '⏳ $msg');
          },
        );
        await _sendMessage(chatId, '✅ ${result.details ?? "Done"}');
      } else {
        // It's a plain text response
        await _sendMessage(chatId, '💬 $aiResponse');
      }
    } catch (e) {
      await _sendMessage(chatId, '❌ Error: $e');
    }
  }

  Future<void> _sendMessage(String chatId, String text) async {
    if (_botToken.isEmpty) return;
    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/sendMessage');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': chatId,
          'text': text,
        }),
      );
    } catch (e) {
      // Never log the exception itself: http's ClientException commonly
      // embeds the request URI, which contains the bot token.
      if (kDebugMode) {
        print('Failed to send telegram message: ${e.runtimeType}');
      }
    }
  }

  void dispose() {
    stopPolling();
  }
}
