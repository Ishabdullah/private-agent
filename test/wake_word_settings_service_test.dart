import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_agent/models/wake_word_config.dart';
import 'package:private_agent/services/wake_word_settings_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadConfig returns null when nothing has been saved', () async {
    final service = WakeWordSettingsService();
    final config = await service.loadConfig();
    expect(config, isNull);
    expect(service.isConfigured, isFalse);
  });

  test('saveConfig then loadConfig round-trips all fields', () async {
    final service = WakeWordSettingsService();
    final created = DateTime.utc(2026, 1, 1);
    final verified = DateTime.utc(2026, 1, 2);
    final original = WakeWordConfig(
      assistantName: 'Nova',
      wakePhrase: 'Hey Nova',
      tier: WakeWordTier.curated,
      modelAssetPathOrFileUri: 'assets/wake_words/nova.ppn',
      engine: WakeWordEngine.porcupine,
      enabled: true,
      sensitivity: 0.7,
      createdAt: created,
      lastVerifiedAt: verified,
    );

    await service.saveConfig(original);

    final reloaded = WakeWordSettingsService();
    final loaded = await reloaded.loadConfig();

    expect(loaded, isNotNull);
    expect(loaded!.assistantName, 'Nova');
    expect(loaded.wakePhrase, 'Hey Nova');
    expect(loaded.tier, WakeWordTier.curated);
    expect(loaded.modelAssetPathOrFileUri, 'assets/wake_words/nova.ppn');
    expect(loaded.engine, WakeWordEngine.porcupine);
    expect(loaded.enabled, isTrue);
    expect(loaded.sensitivity, 0.7);
    expect(loaded.createdAt, created);
    expect(loaded.lastVerifiedAt, verified);
  });

  test('setEnabled toggles persisted enabled flag without touching other fields', () async {
    final service = WakeWordSettingsService();
    await service.saveConfig(WakeWordConfig(
      assistantName: 'Nova',
      wakePhrase: 'Hey Nova',
      tier: WakeWordTier.curated,
      engine: WakeWordEngine.porcupine,
      enabled: true,
      sensitivity: 0.5,
      createdAt: DateTime.utc(2026, 1, 1),
    ));

    await service.setEnabled(false);

    final reloaded = await WakeWordSettingsService().loadConfig();
    expect(reloaded!.enabled, isFalse);
    expect(reloaded.assistantName, 'Nova');
  });

  test('clearConfig removes the stored config', () async {
    final service = WakeWordSettingsService();
    await service.saveConfig(WakeWordConfig(
      assistantName: 'Nova',
      wakePhrase: 'Hey Nova',
      tier: WakeWordTier.curated,
      engine: WakeWordEngine.porcupine,
      enabled: true,
      sensitivity: 0.5,
      createdAt: DateTime.utc(2026, 1, 1),
    ));

    await service.clearConfig();

    expect(service.isConfigured, isFalse);
    final reloaded = await WakeWordSettingsService().loadConfig();
    expect(reloaded, isNull);
  });

  test('isPresetName is case-insensitive and rejects unknown names', () {
    expect(WakeWordSettingsService.isPresetName('nova'), isTrue);
    expect(WakeWordSettingsService.isPresetName('NOVA'), isTrue);
    expect(WakeWordSettingsService.isPresetName('Jarvis'), isFalse);
  });

  test('tierForName is always customKeywordSpotting (Vosk-only, no Porcupine tiers)', () {
    final service = WakeWordSettingsService();
    expect(service.tierForName('Aigentik'), WakeWordTier.customKeywordSpotting);
    expect(service.tierForName('Bumblebee'), WakeWordTier.customKeywordSpotting);
  });
}
