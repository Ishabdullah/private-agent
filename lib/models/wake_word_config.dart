enum WakeWordTier { curated, customGenerated, customKeywordSpotting }

enum WakeWordEngine { porcupine, vosk, sherpaOnnx, none }

class WakeWordConfig {
  final String assistantName;
  final String wakePhrase;
  final WakeWordTier tier;
  final String? modelAssetPathOrFileUri;
  final WakeWordEngine engine;
  final bool enabled;
  final double sensitivity;
  final DateTime createdAt;
  final DateTime? lastVerifiedAt;

  const WakeWordConfig({
    required this.assistantName,
    required this.wakePhrase,
    required this.tier,
    this.modelAssetPathOrFileUri,
    required this.engine,
    required this.enabled,
    required this.sensitivity,
    required this.createdAt,
    this.lastVerifiedAt,
  });

  WakeWordConfig copyWith({
    String? assistantName,
    String? wakePhrase,
    WakeWordTier? tier,
    String? modelAssetPathOrFileUri,
    WakeWordEngine? engine,
    bool? enabled,
    double? sensitivity,
    DateTime? createdAt,
    DateTime? lastVerifiedAt,
  }) {
    return WakeWordConfig(
      assistantName: assistantName ?? this.assistantName,
      wakePhrase: wakePhrase ?? this.wakePhrase,
      tier: tier ?? this.tier,
      modelAssetPathOrFileUri:
          modelAssetPathOrFileUri ?? this.modelAssetPathOrFileUri,
      engine: engine ?? this.engine,
      enabled: enabled ?? this.enabled,
      sensitivity: sensitivity ?? this.sensitivity,
      createdAt: createdAt ?? this.createdAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
    );
  }

  factory WakeWordConfig.fromJson(Map<String, dynamic> json) {
    return WakeWordConfig(
      assistantName: json['assistant_name'] as String? ?? '',
      wakePhrase: json['wake_phrase'] as String? ?? '',
      tier: WakeWordTier.values.firstWhere(
        (t) => t.name == json['tier'],
        orElse: () => WakeWordTier.curated,
      ),
      modelAssetPathOrFileUri: json['model_asset_path_or_file_uri'] as String?,
      engine: WakeWordEngine.values.firstWhere(
        (e) => e.name == json['engine'],
        orElse: () => WakeWordEngine.none,
      ),
      enabled: json['enabled'] as bool? ?? false,
      sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 0.5,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastVerifiedAt: json['last_verified_at'] != null
          ? DateTime.parse(json['last_verified_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'assistant_name': assistantName,
      'wake_phrase': wakePhrase,
      'tier': tier.name,
      'model_asset_path_or_file_uri': modelAssetPathOrFileUri,
      'engine': engine.name,
      'enabled': enabled,
      'sensitivity': sensitivity,
      'created_at': createdAt.toIso8601String(),
      'last_verified_at': lastVerifiedAt?.toIso8601String(),
    };
  }
}
