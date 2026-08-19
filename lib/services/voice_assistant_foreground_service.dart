import 'package:flutter/services.dart';

/// Dart-side bridge to the native `VoiceAssistantForegroundService`.
/// Phase 5a proved the foreground-service shell; Phase 5b wires up the
/// actual sherpa-onnx KeywordSpotter audio loop natively and this class's
/// [onWakeWordDetected] handoff, plus [resumeListening] so the wake-word
/// loop (paused by the native side the moment it fires, to avoid two
/// simultaneous microphone consumers) picks back up once a voice turn ends.
/// See docs/ANDROID_DIGITAL_ASSISTANT_IMPLEMENTATION_PLAN.md Section 7/8.3.2.
class VoiceAssistantForegroundService {
  static const _channel = MethodChannel('com.privateagent/voice_assistant');

  /// Called with the detected assistant name (e.g. "NOVA") whenever the
  /// native KWS loop fires. Set this before calling [start].
  static void Function(String assistantName)? onWakeWordDetected;

  /// Called (Phase 9, optional/additive) whenever the OS invokes
  /// PrivateAgent as the system assistant — long-press home / the assistant
  /// gesture, once the user has selected it via [requestAssistantRole] in
  /// Settings — relayed from `AssistantInteractionSession` via
  /// `MainActivity`. Same shape as [onWakeWordDetected] since Dart should
  /// treat this identically: just another automatic trigger for a voice
  /// turn, not a second pipeline (Section 7's "reuse, don't rewrite").
  static void Function(String? assistantName)? onAssistantGestureInvoked;

  static bool _handlerRegistered = false;

  /// Registers the platform-channel handler for native → Dart calls. Must
  /// be called unconditionally on app start (not just when the user enables
  /// listening) — the native foreground service can outlive the Dart
  /// process being killed and relaunch the app via a wake-word intent, in
  /// which case [start] is never called in the new process.
  static void ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWakeWordDetected') {
        final name = (call.arguments as Map?)?['assistantName'] as String?;
        if (name != null) onWakeWordDetected?.call(name);
      } else if (call.method == 'onAssistantGestureInvoked') {
        final name = (call.arguments as Map?)?['assistantName'] as String?;
        onAssistantGestureInvoked?.call(name);
      }
    });
  }

  static Future<void> start() async {
    ensureHandlerRegistered();
    await _channel.invokeMethod('startListening');
  }

  static Future<void> stop() async {
    await _channel.invokeMethod('stopListening');
  }

  static Future<void> resumeListening() async {
    await _channel.invokeMethod('resumeListening');
  }

  static Future<bool> isListening() async {
    final result = await _channel.invokeMethod<bool>('isListening');
    return result ?? false;
  }
}
