import 'package:flutter/services.dart';

/// Dart-side bridge to the native `VoiceAssistantForegroundService` (Phase 5a
/// shell — see docs/ANDROID_DIGITAL_ASSISTANT_IMPLEMENTATION_PLAN.md Section 7).
/// Currently only starts/stops the foreground service and its notification;
/// no wake-word engine is wired in yet (Phase 5b).
class VoiceAssistantForegroundService {
  static const _channel = MethodChannel('com.privateagent/voice_assistant');

  static Future<void> start() async {
    await _channel.invokeMethod('startListening');
  }

  static Future<void> stop() async {
    await _channel.invokeMethod('stopListening');
  }

  static Future<bool> isListening() async {
    final result = await _channel.invokeMethod<bool>('isListening');
    return result ?? false;
  }
}
