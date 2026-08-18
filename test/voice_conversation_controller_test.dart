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
  final List<VoiceListenMode> modesUsed = [];
  int startListeningCalls = 0;
  bool hang = false;

  /// When set, `startListening` emits these as partial results (in order)
  /// via `onPartialResult` and then never calls `onResult`/`onDone` for that
  /// invocation — used to simulate dictation captures that only resolve via
  /// the controller's timeout fallback.
  List<String>? partialsThenHang;

  FakeVoiceService(this.transcriptQueue);

  @override
  Future<void> init() async {}

  @override
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
    VoiceListenMode mode = VoiceListenMode.confirmation,
    Function(String)? onPartialResult,
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    startListeningCalls++;
    modesUsed.add(mode);
    // Always yield a real microtask so overlapping calls to startTurn()
    // have a chance to observe in-progress state.
    await Future.delayed(Duration.zero);
    if (hang) return; // simulate a permission-denied / silent hang

    if (partialsThenHang != null) {
      for (final p in partialsThenHang!) {
        onPartialResult?.call(p);
      }
      return; // never resolves — the controller's timeout must take over
    }

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
  final List<bool> voiceResponseStyleCalls = [];
  FakeAiService(this.responder);

  @override
  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
    bool voiceResponseStyle = false,
  }) {
    voiceResponseStyleCalls.add(voiceResponseStyle);
    return responder(message);
  }
}

class FakeActionHandler extends ActionHandler {
  final Future<AgentActionResult> Function(AgentAction action) responder;
  final List<String> progressMessages;
  FakeActionHandler(this.responder, {this.progressMessages = const []});

  @override
  Future<AgentActionResult> execute(
    AgentAction action, {
    AiService? aiService,
    void Function(String)? onProgress,
  }) async {
    for (final m in progressMessages) {
      onProgress?.call(m);
    }
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
      // make_call is a destructive action (confirmed before running as of
      // Phase 7) — queue an affirmative reply so this test still exercises
      // the actual call attempt and its failure, not the confirmation guard.
      final voice = FakeVoiceService(['call mom', 'yes']);
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

      expect(voice.spoken, [
        'Calling Mom. Say yes to confirm, or no to cancel.',
        'Calling Mom. Contact not found',
      ]);
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

    test('confirmation mode is still the default for startTurn() with no args', () async {
      final voice = FakeVoiceService(['what time is it']);
      final ai = FakeAiService((msg) => streamOf('It is 3 PM.'));
      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
      );

      await controller.startTurn();

      expect(voice.modesUsed, [VoiceListenMode.confirmation]);
    });

    test('dictation mode: partial results stream via onPartialTranscript, final result completes the turn', () async {
      final voice = FakeVoiceService(['turn on the flashlight']);
      final ai = FakeAiService((msg) => streamOf('Done.'));
      final partials = <String>[];

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        onPartialTranscript: partials.add,
      );

      await controller.startTurn(mode: VoiceListenMode.dictation);

      expect(voice.modesUsed, [VoiceListenMode.dictation]);
      expect(voice.spoken, ['Done.']);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('dictation mode: falls back to the latest partial transcript on timeout instead of dropping it', () async {
      final voice = FakeVoiceService([])..partialsThenHang = ['turn on', 'turn on the flash', 'turn on the flashlight'];
      final ai = FakeAiService((msg) => streamOf('Done.'));
      String? transcript;

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
        onTranscript: (t) => transcript = t,
        initialListenTimeout: const Duration(milliseconds: 50),
      );

      await controller.startTurn(mode: VoiceListenMode.dictation);

      expect(transcript, 'turn on the flashlight');
      expect(voice.spoken, ['Done.']);
      expect(controller.state, VoiceConversationState.idle);
    });

    test('voice turns request the TTS-friendly response style', () async {
      final voice = FakeVoiceService(['what time is it']);
      final ai = FakeAiService((msg) => streamOf('It is 3 PM.'));

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: ActionHandler(),
        voiceService: voice,
      );

      await controller.startTurn();

      expect(ai.voiceResponseStyleCalls, [true]);
    });

    test('send_sms is confirmed before executing: "yes" runs the action', () async {
      final voice = FakeVoiceService(['text mom saying running late', 'yes']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "send_sms", "params": {"contact_name": "Mom", "message": "Running late"}, "response": "Sending Mom: Running late"}',
        ),
      );
      bool actionRan = false;
      final actionHandler = FakeActionHandler((action) async {
        actionRan = true;
        return AgentActionResult(actionType: action.action, success: true, details: 'Sent');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
      );

      await controller.startTurn();

      expect(actionRan, isTrue);
      expect(voice.modesUsed, [VoiceListenMode.confirmation, VoiceListenMode.confirmation]);
      expect(voice.spoken, contains('Sending Mom: Running late. Say yes to confirm, or no to cancel.'));
      expect(voice.spoken.last, 'Sending Mom: Running late');
      expect(controller.state, VoiceConversationState.idle);
    });

    test('make_call is confirmed before executing: "no" skips the action', () async {
      final voice = FakeVoiceService(['call mom', 'no thanks']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "make_call", "params": {"contact_name": "Mom"}, "response": "Calling Mom"}',
        ),
      );
      bool actionRan = false;
      final actionHandler = FakeActionHandler((action) async {
        actionRan = true;
        return AgentActionResult(actionType: action.action, success: true, details: 'Called');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
      );

      await controller.startTurn();

      expect(actionRan, isFalse);
      expect(voice.spoken.last, "Okay, I won't do that.");
      expect(controller.state, VoiceConversationState.idle);
    });

    test('destructive-action confirmation with no reply defaults to safe/cancelled, action never runs', () async {
      // Only one queued transcript ("call mom") — the confirmation capture's
      // startListening call finds an empty queue and resolves via onDone(),
      // i.e. no reply heard, which must be treated the same as "no".
      final voice = FakeVoiceService(['call mom']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "make_call", "params": {"contact_name": "Mom"}, "response": "Calling Mom"}',
        ),
      );
      bool actionRan = false;
      final actionHandler = FakeActionHandler((action) async {
        actionRan = true;
        return AgentActionResult(actionType: action.action, success: true, details: 'Called');
      });

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
        followUpListenTimeout: const Duration(milliseconds: 50),
      );

      await controller.startTurn();

      expect(actionRan, isFalse);
      expect(voice.spoken.last, "Okay, I won't do that.");
    });

    test('progress narration speaks "On it." once and a checkpoint every 4th step, not every step', () async {
      final voice = FakeVoiceService(['open the app and do the thing']);
      final ai = FakeAiService(
        (msg) => streamOf(
          '{"action": "execute_task", "params": {"goal": "do the thing"}, "response": "Done with the thing"}',
        ),
      );
      final progressSteps = [
        'Starting task: do the thing',
        'Step 1: Clicked "Foo" (reasoning)',
        'Step 2: Clicked "Bar" (reasoning)',
        'Step 3: Clicked "Baz" (reasoning)',
        'Step 4: Clicked "Qux" (reasoning)',
        'Step 5: Clicked "Quux" (reasoning)',
        'Task complete.',
      ];
      final actionHandler = FakeActionHandler(
        (action) async => AgentActionResult(actionType: action.action, success: true, details: 'Done'),
        progressMessages: progressSteps,
      );
      final progressUi = <String>[];

      final controller = VoiceConversationController(
        aiService: ai,
        actionHandler: actionHandler,
        voiceService: voice,
        onProgress: progressUi.add,
      );

      await controller.startTurn();

      // All progress messages still reach the UI callback unfiltered.
      expect(progressUi, progressSteps);
      // Only "On it." + the step-4 checkpoint + the final spoken response are
      // actually spoken — not every one of the 7 progress messages.
      expect(voice.spoken, ['On it.', 'Still working, step 4.', 'Done with the thing']);
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
