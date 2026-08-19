import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/tts_settings.dart';

/// Which `speech_to_text` listen mode to use for a capture.
///
/// - [confirmation]: today's push-to-talk behavior — short utterance, no
///   partial results, finalizes quickly on silence.
/// - [dictation]: longer, conversational captures (used for wake-word/voice
///   turns) — tolerates mid-sentence pauses and streams partial results so a
///   caller can show live transcription, but still needs an explicit
///   [VoiceService.startListening] `pauseFor`/timeout to end on silence.
enum VoiceListenMode { confirmation, dictation }

class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isListening = false;
  bool _ttsConfigured = false;

  bool get isListening => _isListening;

  Future<void> init() async {
    // Without this, `await _tts.speak(...)` resolves as soon as playback
    // *starts*, not when it finishes — any caller that starts listening
    // right after `await speak(...)` (e.g. the destructive-action
    // confirmation prompt, or a follow-up-question re-listen) would start
    // recording while the TTS was still talking, and the mic's
    // silence-based cutoff would then end the capture before the user got
    // a chance to actually respond. Device-reported symptom: the
    // confirmation prompt's yes/no capture ended before the user could
    // answer.
    await _tts.awaitSpeakCompletion(true);

    // TTS configuration is independent of STT init succeeding — if the
    // speech recognizer fails to initialize (e.g. no RecognitionService on
    // this device), speak() should still work with sane defaults rather
    // than silently using flutter_tts's unconfigured engine defaults.
    if (!_ttsConfigured) {
      await applyTtsSettings(const TtsSettings());
    }

    if (_isInitialized) return;
    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
      },
    );
  }

  /// Applies user-configured rate/pitch/volume/voice to the TTS engine.
  /// Safe to call again any time settings change — does not touch STT.
  Future<void> applyTtsSettings(TtsSettings settings) async {
    await _tts.setLanguage(settings.language);
    await _tts.setSpeechRate(settings.rate);
    await _tts.setVolume(settings.volume);
    await _tts.setPitch(settings.pitch);
    if (settings.voiceName != null) {
      try {
        await _tts.setVoice({
          'name': settings.voiceName!,
          'locale': settings.voiceLocale ?? settings.language,
        });
      } catch (_) {
        // Voice may no longer exist on this device (engine changed, OS
        // update) — fall back to the language default rather than throwing.
      }
    }
    _ttsConfigured = true;
  }

  /// Lists voices the on-device TTS engine reports, as raw
  /// `{"name": ..., "locale": ...}` maps (flutter_tts's own shape) — the
  /// available set is engine/OS-dependent and can legitimately be empty.
  Future<List<Map<String, String>>> getVoices() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map(
            (v) => {
              'name': (v['name'] ?? '').toString(),
              'locale': (v['locale'] ?? '').toString(),
            },
          )
          .where((v) => v['name']!.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Start listening for speech. Returns transcribed text via callback.
  ///
  /// [mode] defaults to [VoiceListenMode.confirmation] (today's push-to-talk
  /// behavior, unchanged). Pass [VoiceListenMode.dictation] for longer,
  /// conversational captures — it streams interim text via [onPartialResult]
  /// and only finalizes after [pauseFor] of silence, so callers should size
  /// their own timeout accordingly rather than relying on a quick auto-stop.
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
    VoiceListenMode mode = VoiceListenMode.confirmation,
    Function(String)? onPartialResult,
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return;

    _isListening = true;
    final dictation = mode == VoiceListenMode.dictation;

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          onResult(result.recognizedWords);
          onDone();
        } else if (dictation) {
          onPartialResult?.call(result.recognizedWords);
        }
      },
      listenOptions: dictation
          ? stt.SpeechListenOptions(
              listenMode: stt.ListenMode.dictation,
              partialResults: true,
              pauseFor: pauseFor,
            )
          : stt.SpeechListenOptions(
              listenMode: stt.ListenMode.confirmation,
              partialResults: false,
            ),
    );
  }

  /// Stop listening
  Future<void> stopListening() async {
    _isListening = false;
    await _speech.stop();
  }

  /// Speak text aloud. Strips markdown/URLs/emoji first — the LLM is asked
  /// for TTS-friendly output (`voiceResponseStyle`) but nothing enforces
  /// that, and typed-chat replies aren't asked at all, so this is the one
  /// choke point every spoken string passes through.
  Future<void> speak(String text) async {
    if (!_ttsConfigured) await applyTtsSettings(const TtsSettings());
    final clean = sanitizeForSpeech(text);
    if (clean.isEmpty) return;
    await _tts.speak(clean);
  }

  /// Strips markdown formatting, code spans/fences, bare URLs, and emoji
  /// from [text] so a TTS engine doesn't read punctuation/syntax aloud.
  /// Pure and side-effect-free so it's directly unit-testable.
  static String sanitizeForSpeech(String text) {
    var result = text;
    // Fenced code blocks (```...```) — drop entirely, code isn't speakable.
    result = result.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    // Inline code spans: `code` -> code
    result = result.replaceAllMapped(
      RegExp(r'`([^`]*)`'),
      (m) => m.group(1) ?? '',
    );
    // Markdown links/images: [text](url) -> text, ![alt](url) -> alt
    result = result.replaceAllMapped(
      RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    // Bare URLs.
    result = result.replaceAll(RegExp(r'https?://\S+'), '');
    // Bold/italic/strikethrough markers.
    result = result.replaceAll(RegExp(r'(\*\*\*|\*\*|\*|__|~~|_)'), '');
    // Markdown headers/blockquote/list markers at line start.
    result = result.replaceAll(RegExp(r'^\s{0,3}[#>*-]+\s*', multiLine: true), '');
    // Emoji and other pictographic symbols.
    result = result.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]',
        unicode: true,
      ),
      '',
    );
    // Collapse all whitespace (including newlines left by removed blocks)
    // into single spaces — TTS engines don't need line breaks preserved.
    return result.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Stop speaking
  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
