import 'dart:async';

import '../models/agent_action.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'voice_service.dart';

enum VoiceConversationState {
  idle,
  woken,
  listening,
  transcribing,
  thinking,
  speaking,
  continuingConversation,
}

/// Orchestrates a voice turn: capture speech → send to the existing agent
/// stack (`AiService`/`ActionHandler`, unchanged) → speak the result.
///
/// This is glue, not a second agent — it never talks to the LLM, the
/// accessibility service, or app launching directly. Phase 2 wires this up
/// against the existing push-to-talk `VoiceService` (no wake word yet); a
/// wake-word engine (Phase 3+) will call [startTurn] the same way a manual
/// mic-button tap does today.
class VoiceConversationController {
  final AiService aiService;
  final ActionHandler actionHandler;
  final VoiceService voiceService;

  /// Called whenever the state machine transitions, for UI/observability.
  final void Function(VoiceConversationState state)? onStateChanged;

  /// Called with the user's recognized transcript as soon as it's final,
  /// before the request is sent to the LLM — lets a caller render it as a
  /// chat bubble immediately instead of waiting for the whole turn.
  final void Function(String transcript)? onTranscript;

  /// Called with the final spoken response text of a turn (after any action
  /// has run), so a caller can also render it as text if desired.
  final void Function(String response, {required bool success})? onResponse;

  /// Forwarded to `ActionHandler.execute` for multi-step task progress
  /// narration in the UI. Not spoken aloud by default — speaking every
  /// intermediate step would be noisy; only the final result is spoken.
  final void Function(String message)? onProgress;

  /// How long to wait for a transcript before giving up and returning to
  /// Idle. `VoiceService` doesn't surface mic-permission/init failures as an
  /// error callback, so this is the safety net that prevents a silent hang.
  final Duration initialListenTimeout;

  /// Bounded window for a follow-up turn (no wake word required) after the
  /// assistant asks what looks like a clarifying question.
  final Duration followUpListenTimeout;

  VoiceConversationController({
    required this.aiService,
    required this.actionHandler,
    required this.voiceService,
    this.onStateChanged,
    this.onTranscript,
    this.onResponse,
    this.onProgress,
    this.initialListenTimeout = const Duration(seconds: 20),
    this.followUpListenTimeout = const Duration(seconds: 10),
  });

  VoiceConversationState _state = VoiceConversationState.idle;
  VoiceConversationState get state => _state;

  bool _cancelled = false;

  void _setState(VoiceConversationState next) {
    _state = next;
    onStateChanged?.call(next);
  }

  /// Starts a voice turn. No-op if a turn is already in progress.
  Future<void> startTurn() async {
    if (_state != VoiceConversationState.idle &&
        _state != VoiceConversationState.continuingConversation) {
      return;
    }
    _cancelled = false;
    _setState(VoiceConversationState.woken);
    await _listenAndRespond(timeout: initialListenTimeout);
  }

  /// Cancels the current turn and returns to Idle.
  void cancel() {
    _cancelled = true;
    voiceService.stopListening();
    voiceService.stopSpeaking();
    _setState(VoiceConversationState.idle);
  }

  Future<void> _listenAndRespond({required Duration timeout}) async {
    _setState(VoiceConversationState.listening);
    final transcript = await _captureTranscript(timeout: timeout);
    if (_cancelled) return;

    if (transcript == null || transcript.trim().isEmpty) {
      _setState(VoiceConversationState.idle);
      return;
    }

    _setState(VoiceConversationState.transcribing);
    onTranscript?.call(transcript.trim());
    _setState(VoiceConversationState.thinking);

    String spokenResponse;
    bool success = true;
    bool followUpLikely = false;

    try {
      final accumulated = StringBuffer();
      await for (final chunk in aiService.sendMessageStream(
        transcript,
        isAgentMode: true,
      )) {
        accumulated.write(chunk);
      }
      final text = accumulated.toString();

      final AgentAction? action = aiService.parseAction(text);
      if (action != null) {
        final result = await actionHandler.execute(
          action,
          aiService: aiService,
          onProgress: onProgress,
        );
        success = result.success;
        spokenResponse = action.response.isNotEmpty
            ? action.response
            : (result.details ?? (success ? 'Done.' : 'Something went wrong.'));
        if (!success && result.details != null && action.response.isNotEmpty) {
          spokenResponse = '${action.response}. ${result.details}';
        }
      } else {
        spokenResponse = text.trim().isEmpty
            ? "Sorry, I didn't get a response."
            : text.trim();
        followUpLikely = spokenResponse.endsWith('?');
      }
    } catch (e) {
      success = false;
      spokenResponse = 'Sorry, I ran into a problem: ${_describeError(e)}';
    }

    if (_cancelled) return;

    onResponse?.call(spokenResponse, success: success);
    _setState(VoiceConversationState.speaking);
    await voiceService.speak(spokenResponse);
    if (_cancelled) return;

    if (followUpLikely) {
      _setState(VoiceConversationState.continuingConversation);
      await _listenAndRespond(timeout: followUpListenTimeout);
    } else {
      _setState(VoiceConversationState.idle);
    }
  }

  Future<String?> _captureTranscript({required Duration timeout}) async {
    final completer = Completer<String?>();

    try {
      await voiceService.startListening(
        onResult: (text) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        await voiceService.stopListening();
        return null;
      },
    );
  }

  String _describeError(Object e) {
    final msg = e.toString().replaceFirst('Exception: ', '');
    return msg.length > 160 ? '${msg.substring(0, 160)}...' : msg;
  }
}
