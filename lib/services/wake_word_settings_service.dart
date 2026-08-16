import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/wake_word_config.dart';

class WakeWordSettingsService {
  static const _prefsKey = 'wake_word_config';

  /// The ONLY assistant names that get real wake-word detection (Phase 5b
  /// decision, 2026-08-16). sherpa-onnx's KeywordSpotter requires each
  /// keyword to be pre-tokenized into the model's BPE sub-word pieces
  /// offline (confirmed by reading sherpa-onnx's C++ `EncodeBase` — it does
  /// a literal per-token lookup against `tokens.txt`, no on-device
  /// tokenizer exists) — so free-typed names can no longer be supported at
  /// runtime the way the Phase 4 onboarding UI implied. These 5 names were
  /// tokenized at development time via `text2token` and are bundled in
  /// `assets/kws/keywords.txt`; see `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md`
  /// for how to add more. Onboarding must restrict selection to this list.
  static const presetNames = ['Aigentik', 'Nova', 'Codey', 'Juno', 'Milo'];

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

  /// Always `curated` now — every supported name is a pre-tokenized,
  /// bundled model shipped with the app (see [presetNames]), which is
  /// exactly what `WakeWordTier.curated` was defined to mean (Section 8.4).
  WakeWordTier tierForName(String name) => WakeWordTier.curated;
}
