import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/agent_action.dart';
import 'package:private_agent/models/chat_message.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/voice_conversation_controller.dart';
import 'package:private_agent/services/voice_service.dart';

class FakeVoiceService extends VoiceService {
  final List<String?> transcriptQueue;
  final List<String> spoken = [];
  int startListeningCalls = 0;
  bool hang = false;

  FakeVoiceService(this.transcriptQueue);

  @override
  Future<void> init() async {}

  @override
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    startListeningCalls++;
    // Always yield a real microtask so overlapping calls to startTurn()
    // have a chance to observe in-progress state.
    await Future.delayed(Duration.zero);
    if (hang) return; // simulate a permission-denied / silent hang

    final next = transcriptQueue.isNotEmpty ? transcriptQueue.removeAt(0) : null;
    if (next != null) {
      onResult(next);
    } else {
      onDone();
    }
  }

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stopSpeaking() async {}
}

class FakeAiService extends AiService {
  final Stream<String> Function(String message) responder;
  FakeAiService(this.responder);

  @override
  Stream<String> sendMessageStream(String message, {bool isAgentMode = true}) {
    return responder(message);
  }
}

class FakeActionHandler extends ActionHandler {
  final Future<AgentActionResult> Function(AgentAction action) responder;
  FakeActionHandler(this.responder);

  @override
  Future<AgentActionResult> execute(
    AgentAction action, {
    AiService? aiService,
    void Function(String)? onProgress,
  }) {
    return responder(action);
  }
}

Stream<String> streamOf(String s) async* {
  yield s;
}

Stream<String> throwingStream(Object error) async* {
  throw error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceConversationController', () {
    test('plain text turn: listens, thinks, speaks, returns to idle', () async {
      final voice = FakeVoiceService(['what time is it']);
      final ai = FakeAiService((msg) => streamOf('It is 3 PM.'));
      final states = <VoiceConversationState>[];
      final responses = <String>[];

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        onStateChanged: states.add,
        onResponse: (r, {required success}) => responses.add(r),
      );

      await controller.startTurn();

      expect(voice.spoken, ['It is 3 PM.']);
      expect(responses, ['It is 3 PM.']);
      expect(controller.state, VoiceConversationState.idle);
      expect(states.first, VoiceConversationState.woken);
      expect(states.last, VoiceConversationState.idle);
      expect(states, contains(VoiceConversationState.listening));
      expect(states, contains(VoiceConversationState.thinking));
      expect(states, contains(VoiceConversationState.speaking));
    });

    test('action turn: dispatches through ActionHandler and speaks the action response', () async {
      final voice = FakeVoiceService(['open youtube']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "open_app", "params": {"app_name": "YouTube"}, "response": "Opening YouTube"}',
        ),
      );
      AgentAction? capturedAction;
      final actionHandler = FakeActionHandler((action) async {
        capturedAction = action;
        return AgentActionResult(actionType: action.action, success: true, details: 'Opened YouTube');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
      );

      await controller.startTurn();

      expect(capturedAction?.action, 'open_app');
      expect(voice.spoken, ['Opening YouTube']);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('failed action turn: speaks the action response plus failure details', () async {
      final voice = FakeVoiceService(['call mom']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "make_call", "params": {"contact_name": "Mom"}, "response": "Calling Mom"}',
        ),
      );
      final actionHandler = FakeActionHandler((action) async {
        return AgentActionResult(actionType: action.action, success: false, details: 'Contact not found');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
      );

      await controller.startTurn();

      expect(voice.spoken, ['Calling Mom. Contact not found']);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('LLM failure: speaks a graceful error and returns to idle instead of hanging', () async {
      final voice = FakeVoiceService(['do something']);
      final ai = FakeAiService((msg) => throwingStream(Exception('API error (500): boom')));
      bool? successFlag;

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        onResponse: (r, {required success}) => successFlag = success,
      );

      await controller.startTurn();

      expect(voice.spoken.single, contains('Sorry, I ran into a problem'));
      expect(successFlag, isFalse);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('no transcript (mic denied / silent hang): returns to idle without calling the LLM', () async {
      final voice = FakeVoiceService([])..hang = true;
      bool aiCalled = false;
      final ai = FakeAiService((msg) {
        aiCalled = true;
        return streamOf('should not be reached');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        initialListenTimeout: const Duration(milliseconds: 50),
      );

      await controller.startTurn();

      expect(aiCalled, isFalse);
      expect(voice.spoken, isEmpty);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('follow-up question re-opens the mic without requiring another wake trigger', () async {
      final voice = FakeVoiceService(['what is the weather', 'in Paris']);
      final responses = ['What city do you want the weather for?', 'Sunny and 20 degrees.'];
      int call = 0;
      final ai = FakeAiService((msg) => streamOf(responses[call++]));

      final states = <VoiceConversationState>[];
      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        onStateChanged: states.add,
      );

      await controller.startTurn();

      expect(voice.spoken, ['What city do you want the weather for?', 'Sunny and 20 degrees.']);
      expect(voice.startListeningCalls, 2);
      expect(states, contains(VoiceConversationState.continuingConversation));
      expect(controller.state, VoiceConversationState.idle);
    });

    test('startTurn() is a no-op while a turn is already in progress', () async {
      final voice = FakeVoiceService(['first']);
      final ai = FakeAiService((msg) => streamOf('ok'));

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
      );

      final first = controller.startTurn();
      // Fired while the first turn is still mid-flight (FakeVoiceService
      // yields a real microtask before resolving startListening).
      final second = controller.startTurn();

      await Future.wait([first, second]);

      expect(voice.startListeningCalls, 1);
    });

    test('cancel() immediately returns the controller to idle', () async {
      final voice = FakeVoiceService(['hello']);
      final ai = FakeAiService((msg) => streamOf('ok'));
      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
      );

      controller.cancel();

      expect(controller.state, VoiceConversationState.idle);
    });
  });
}
