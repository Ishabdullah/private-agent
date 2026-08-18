/// User-configurable text-to-speech playback settings, applied to every
/// `VoiceService.speak()` call (voice turns and typed-chat plain-text
/// replies alike).
///
/// Ranges follow `flutter_tts`'s normalized scale (confirmed against the
/// pinned `flutter_tts: ^4.2.0`, not assumed): [rate] and [volume] are
/// 0.0-1.0, [pitch] is 0.0-2.0 with 1.0 as the natural midpoint.
class TtsSettings {
  final double rate;
  final double pitch;
  final double volume;

  /// The device TTS engine's voice name (from `FlutterTts.getVoices()`), or
  /// `null` to use the engine's default voice for [language].
  final String? voiceName;
  final String? voiceLocale;
  final String language;

  const TtsSettings({
    this.rate = 0.5,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.voiceName,
    this.voiceLocale,
    this.language = 'en-US',
  });

  static double clampRate(double v) => v.clamp(0.0, 1.0);
  static double clampPitch(double v) => v.clamp(0.0, 2.0);
  static double clampVolume(double v) => v.clamp(0.0, 1.0);

  TtsSettings copyWith({
    double? rate,
    double? pitch,
    double? volume,
    String? voiceName,
    String? voiceLocale,
    bool clearVoice = false,
    String? language,
  }) {
    return TtsSettings(
      rate: rate != null ? clampRate(rate) : this.rate,
      pitch: pitch != null ? clampPitch(pitch) : this.pitch,
      volume: volume != null ? clampVolume(volume) : this.volume,
      voiceName: clearVoice ? null : (voiceName ?? this.voiceName),
      voiceLocale: clearVoice ? null : (voiceLocale ?? this.voiceLocale),
      language: language ?? this.language,
    );
  }

  factory TtsSettings.fromJson(Map<String, dynamic> json) {
    return TtsSettings(
      rate: clampRate((json['rate'] as num?)?.toDouble() ?? 0.5),
      pitch: clampPitch((json['pitch'] as num?)?.toDouble() ?? 1.0),
      volume: clampVolume((json['volume'] as num?)?.toDouble() ?? 1.0),
      voiceName: json['voice_name'] as String?,
      voiceLocale: json['voice_locale'] as String?,
      language: json['language'] as String? ?? 'en-US',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rate': rate,
      'pitch': pitch,
      'volume': volume,
      'voice_name': voiceName,
      'voice_locale': voiceLocale,
      'language': language,
    };
  }
}
