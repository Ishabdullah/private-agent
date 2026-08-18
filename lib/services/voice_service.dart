import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';

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

  bool get isListening => _isListening;

  Future<void> init() async {
    if (_isInitialized) return;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
      },
    );

    // Configure TTS
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
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

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
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
