import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_agent/models/tts_settings.dart';
import 'package:private_agent/services/tts_settings_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadSettings returns defaults when nothing has been saved', () async {
    final service = TtsSettingsService();
    final settings = await service.loadSettings();
    expect(settings.rate, 0.5);
    expect(settings.pitch, 1.0);
    expect(settings.volume, 1.0);
    expect(settings.voiceName, isNull);
    expect(settings.language, 'en-US');
  });

  test('saveSettings then loadSettings round-trips all fields', () async {
    final service = TtsSettingsService();
    const original = TtsSettings(
      rate: 0.8,
      pitch: 1.4,
      volume: 0.6,
      voiceName: 'en-us-x-tpf-local',
      voiceLocale: 'en-US',
      language: 'en-US',
    );

    await service.saveSettings(original);

    final reloaded = await TtsSettingsService().loadSettings();
    expect(reloaded.rate, 0.8);
    expect(reloaded.pitch, 1.4);
    expect(reloaded.volume, 0.6);
    expect(reloaded.voiceName, 'en-us-x-tpf-local');
    expect(reloaded.voiceLocale, 'en-US');
  });

  test('resetToDefaults clears the stored settings', () async {
    final service = TtsSettingsService();
    await service.saveSettings(const TtsSettings(rate: 0.9));

    await service.resetToDefaults();

    final reloaded = await TtsSettingsService().loadSettings();
    expect(reloaded.rate, 0.5);
  });

  test('current returns the in-memory settings, defaults before any load', () {
    final service = TtsSettingsService();
    expect(service.current.rate, 0.5);
  });

  group('TtsSettings clamping', () {
    test('copyWith clamps rate/volume to 0.0-1.0 and pitch to 0.0-2.0', () {
      const base = TtsSettings();
      final clamped = base.copyWith(rate: 5.0, pitch: -1.0, volume: 2.0);
      expect(clamped.rate, 1.0);
      expect(clamped.pitch, 0.0);
      expect(clamped.volume, 1.0);
    });

    test('fromJson clamps out-of-range persisted values', () {
      final settings = TtsSettings.fromJson({
        'rate': 3.0,
        'pitch': 10.0,
        'volume': -5.0,
      });
      expect(settings.rate, 1.0);
      expect(settings.pitch, 2.0);
      expect(settings.volume, 0.0);
    });

    test('copyWith clearVoice removes voiceName/voiceLocale', () {
      const withVoice = TtsSettings(voiceName: 'x', voiceLocale: 'en-US');
      final cleared = withVoice.copyWith(clearVoice: true);
      expect(cleared.voiceName, isNull);
      expect(cleared.voiceLocale, isNull);
    });
  });
}
