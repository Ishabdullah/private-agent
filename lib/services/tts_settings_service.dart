import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tts_settings.dart';

class TtsSettingsService {
  static const _prefsKey = 'tts_settings';

  TtsSettings? _settings;

  TtsSettings get current => _settings ?? const TtsSettings();

  Future<TtsSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) {
      _settings = const TtsSettings();
      return _settings!;
    }
    try {
      _settings = TtsSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      _settings = const TtsSettings();
    }
    return _settings!;
  }

  Future<void> saveSettings(TtsSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
    _settings = settings;
  }

  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    _settings = const TtsSettings();
  }
}
