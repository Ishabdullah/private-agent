import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/wake_word_config.dart';

class WakeWordSettingsService {
  static const _prefsKey = 'wake_word_config';

  /// Suggested assistant-name presets shown as tappable tiles during
  /// onboarding. Purely a UX convenience — per the Phase 5 decision
  /// (2026-08-16, sherpa-onnx open-vocabulary KWS), picking a preset vs.
  /// typing a custom name is technically identical: both go through the same
  /// engine with the same cost profile, no per-phrase model training needed.
  static const presetNames = ['Nova', 'Aigentik', 'Private'];

  /// The only wake-word engine this app ships (Phase 5 decision; supersedes
  /// the Phase 3 Vosk-only decision after vosk-android/vosk_flutter were
  /// found to be dead/Dart-3-incompatible — see plan doc Section 8.3.2).
  static const defaultEngine = WakeWordEngine.sherpaOnnx;

  WakeWordConfig? _config;

  WakeWordConfig? get config => _config;

  bool get isConfigured => _config != null;

  static bool isPresetName(String name) =>
      presetNames.any((n) => n.toLowerCase() == name.trim().toLowerCase());

  Future<WakeWordConfig?> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) {
      _config = null;
      return null;
    }
    try {
      _config = WakeWordConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      _config = null;
    }
    return _config;
  }

  Future<void> saveConfig(WakeWordConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
    _config = config;
  }

  Future<void> setEnabled(bool enabled) async {
    if (_config == null) return;
    await saveConfig(_config!.copyWith(enabled: enabled));
  }

  Future<void> clearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    _config = null;
  }

  /// Always `customKeywordSpotting` under the single-engine, open-vocabulary
  /// KWS decision — kept as a method (rather than a constant) so a future
  /// session reintroducing Porcupine only needs to change this one place.
  WakeWordTier tierForName(String name) => WakeWordTier.customKeywordSpotting;
}
