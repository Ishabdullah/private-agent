import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/app_launcher_service.dart';
import 'package:private_agent/services/notification_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';
import 'package:private_agent/services/shizuku_service.dart';
import 'package:private_agent/services/task_executor.dart';

/// `NotificationService` wraps `flutter_local_notifications`, whose
/// platform-interface singleton is never assigned in a pure `flutter_test`
/// environment (unlike a plain MethodChannel, mocking the channel alone
/// doesn't help -- `FlutterLocalNotificationsPlatform.instance` throws
/// `LateInitializationError` before any channel call happens). No-opping
/// it here is the same testability need `TaskExecutor`'s other
/// dependencies already solve via constructor injection.
class FakeNotificationService extends NotificationService {
  @override
  Future<void> showTaskCompleteNotification(String title, String body) async {}
}

/// `TaskExecutor` had zero test coverage before this file (noted as an open
/// gap since Phase 1 -- it needed a MethodChannel-mocking strategy decided
/// first, which `screen_automation_service_test.dart` already established;
/// this file reuses that exact pattern). Scope here is deliberately narrow:
/// the brand-new `onConfirmRiskyTap` guard (Phase 11's fix for the
/// multi-step-task confirmation gap), which had no coverage of its own at
/// all. The full step-loop/retry/recovery machinery is a much larger
/// surface better tackled as its own follow-up.
class FakeAiService extends AiService {
  final List<String> responses;
  int _i = 0;
  final List<String> promptsSeen = [];

  FakeAiService(this.responses);

  @override
  bool get useScreenCompression => false;

  @override
  int get maxSteps => 10;

  @override
  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt) async {
    promptsSeen.add(prompt);
    final content = responses[_i.clamp(0, responses.length - 1)];
    _i++;
    return AiResponse(content, 10);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.privateagent/accessibility');
  // TaskExecutor calls NotificationService.showTaskCompleteNotification on
  // every completion/cancellation path; flutter_local_notifications' own
  // channel needs a mock handler too, or its unmocked MethodChannel calls
  // throw MissingPluginException and take the whole executeTask() call down
  // with them -- an orthogonal plugin-wiring concern, not something this
  // file is testing, so it's stubbed permissively (every call succeeds).
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  final clickedTexts = <String>[];

  setUp(() {
    clickedTexts.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (call) async {
      if (call.method == 'requestNotificationsPermission') return true;
      return null;
    });
    setHandler((call) async {
      switch (call.method) {
        case 'isServiceRunning':
          return true;
        case 'dumpScreen':
          return [
            {
              'index': 0,
              'text': 'Send',
              'contentDescription': '',
              'className': 'android.widget.Button',
              'isClickable': true,
              'isEditable': false,
              'isScrollable': false,
              'bounds': {'left': 0, 'top': 0, 'right': 100, 'bottom': 50},
            },
          ];
        case 'getCurrentPackage':
          return 'com.whatsapp';
        case 'clickByText':
          clickedTexts.add(call.arguments['text'] as String);
          return true;
        case 'logToNative':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  TaskExecutor buildExecutor(
    FakeAiService ai, {
    Future<bool> Function(String description)? onConfirmRiskyTap,
  }) {
    return TaskExecutor(
      aiService: ai,
      screenService: ScreenAutomationService(),
      appLauncher: AppLauncherService(),
      shizukuService: ShizukuService(),
      notificationService: FakeNotificationService(),
      onConfirmRiskyTap: onConfirmRiskyTap,
    );
  }

  test(
    'a click_text step whose label matches a risky keyword ("Send") is confirmed '
    'first, and proceeds when the confirmation is accepted',
    () async {
      final ai = FakeAiService([
        '{"action": "click_text", "params": {"text": "Send"}, "reasoning": "sending the message", "is_complete": false}',
        '{"action": "done", "params": {}, "reasoning": "sent", "is_complete": true}',
      ]);
      final confirmedDescriptions = <String>[];
      final executor = buildExecutor(
        ai,
        onConfirmRiskyTap: (description) async {
          confirmedDescriptions.add(description);
          return true;
        },
      );

      await executor.executeTask('send hello to John');

      expect(confirmedDescriptions, ['Tap "Send"?']);
      expect(clickedTexts, ['Send']);
    },
  );

  test(
    'declining the risky-tap confirmation stops the task before the tap happens',
    () async {
      final ai = FakeAiService([
        '{"action": "click_text", "params": {"text": "Send"}, "reasoning": "sending the message", "is_complete": false}',
      ]);
      final executor = buildExecutor(
        ai,
        onConfirmRiskyTap: (description) async => false,
      );

      final result = await executor.executeTask('send hello to John');

      expect(clickedTexts, isEmpty);
      expect(result, contains("stopped"));
    },
  );

  test(
    'a non-risky click_text step (e.g. "Settings") never invokes the confirmation '
    'callback at all',
    () async {
      final ai = FakeAiService([
        '{"action": "click_text", "params": {"text": "Settings"}, "reasoning": "opening settings", "is_complete": false}',
        '{"action": "done", "params": {}, "reasoning": "done", "is_complete": true}',
      ]);
      var confirmCallCount = 0;
      final executor = buildExecutor(
        ai,
        onConfirmRiskyTap: (description) async {
          confirmCallCount++;
          return true;
        },
      );

      // Deliberately avoids any word matching getNavigationShortcut's
      // keyword patterns (task_json_utils.dart) or its "^open X" regex --
      // those bypass the LLM (and this whole click_text scenario) entirely
      // for a handful of common goals like "open settings".
      await executor.executeTask('tap the profile icon');

      expect(confirmCallCount, 0);
      expect(clickedTexts, ['Settings']);
    },
  );

  test(
    'with no onConfirmRiskyTap wired at all, a risky tap proceeds unconfirmed '
    '(matches every call site\'s behavior before this guard existed)',
    () async {
      final ai = FakeAiService([
        '{"action": "click_text", "params": {"text": "Send"}, "reasoning": "sending", "is_complete": false}',
        '{"action": "done", "params": {}, "reasoning": "sent", "is_complete": true}',
      ]);
      final executor = buildExecutor(ai); // onConfirmRiskyTap left null

      await executor.executeTask('send hello to John');

      expect(clickedTexts, ['Send']);
    },
  );
}
