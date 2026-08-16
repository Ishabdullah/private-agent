import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keystore-backed storage for secrets (API keys, bot tokens), with a
/// one-time migration path for values previously written to plaintext
/// SharedPreferences by earlier app versions.
class SecureSecretStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// Reads [secureKey] from secure storage. If absent, checks
  /// [legacyPrefsKey] in SharedPreferences; if a value is found there, it is
  /// written into secure storage and removed from SharedPreferences before
  /// being returned. Safe to call every app start.
  static Future<String?> readAndMigrate({
    required String secureKey,
    required String legacyPrefsKey,
  }) async {
    final existing = await _storage.read(key: secureKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyPrefsKey);
    if (legacy != null && legacy.isNotEmpty) {
      await _storage.write(key: secureKey, value: legacy);
      await prefs.remove(legacyPrefsKey);
      return legacy;
    }
    return null;
  }

  static Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<void> delete(String key) => _storage.delete(key: key);
}
