import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/agent_action.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/alarm_service.dart';
import 'package:private_agent/services/app_launcher_service.dart';
import 'package:private_agent/services/communication_service.dart';
import 'package:private_agent/services/contacts_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';
import 'package:private_agent/services/system_control_service.dart';

/// Hand-written fake subclasses overriding only the methods `ActionHandler`
/// actually calls -- same pattern already established by
/// `voice_conversation_controller_test.dart`'s fakes, avoiding a mocking
/// library dependency. This is the first coverage `ActionHandler`'s
/// dispatch switch has ever had; it was previously untestable because its
/// dependencies were constructed directly in field initializers with no way
/// to substitute fakes (fixed by the constructor-injection refactor this
/// test file accompanies).
class FakeAppLauncherService extends AppLauncherService {
  String? openedApp;
  String? openedPackage;
  String? openedUrl;

  @override
  Future<String> openApp(String appName) async {
    openedApp = appName;
    return 'Opened $appName';
  }

  @override
  Future<String> openPackage(String packageName) async {
    openedPackage = packageName;
    return 'Opened package $packageName';
  }

  @override
  Future<String> openUrl(String url) async {
    openedUrl = url;
    return 'Opened $url';
  }
}

class FakeContactsService extends ContactsService {
  String? lastQuery;

  @override
  Future<String> searchAndFormat(String query) async {
    lastQuery = query;
    return 'Found 1 contact(s):\n• Mom - 555-1234';
  }
}

class FakeCommunicationService extends CommunicationService {
  String? calledContact;
  String? smsContact;
  String? smsMessage;
  String? emailedTo;

  @override
  Future<String> makeCall({String? contactName, String? phoneNumber}) async {
    calledContact = contactName ?? phoneNumber;
    return 'Calling ${contactName ?? phoneNumber}...';
  }

  @override
  Future<String> sendSms({
    String? contactName,
    String? phoneNumber,
    required String message,
  }) async {
    smsContact = contactName ?? phoneNumber;
    smsMessage = message;
    return 'Opening SMS to ${contactName ?? phoneNumber} with message: "$message"';
  }

  @override
  Future<String> sendEmail({
    required String to,
    String? subject,
    String? body,
  }) async {
    emailedTo = to;
    return 'Opening email to $to';
  }
}

class FakeAlarmService extends AlarmService {
  int? alarmHour;
  int? alarmMinute;
  int? timerSeconds;

  @override
  Future<String> setAlarm({
    required int hour,
    required int minute,
    String? label,
  }) async {
    alarmHour = hour;
    alarmMinute = minute;
    return 'Alarm set for $hour:$minute';
  }

  @override
  Future<String> setTimer({required int seconds, String? label}) async {
    timerSeconds = seconds;
    return 'Timer set for $seconds seconds';
  }
}

class FakeSystemControlService extends SystemControlService {
  int? volumeLevel;
  int? brightnessLevel;

  @override
  Future<String> setVolume(int level) async {
    volumeLevel = level;
    return 'Volume set to $level';
  }

  @override
  Future<String> setBrightness(int level) async {
    brightnessLevel = level;
    return 'Brightness set to $level';
  }
}

class FakeScreenAutomationService extends ScreenAutomationService {
  String? clickedText;
  String? typedText;
  String? scrolledDirection;
  bool pressedBack = false;
  bool clickShouldSucceed = true;

  @override
  Future<String> getScreenDescription() async => 'MOCK SCREEN CONTENT';

  @override
  Future<bool> clickByText(String text) async {
    clickedText = text;
    return clickShouldSucceed;
  }

  @override
  Future<bool> typeText(String text, {String? fieldHint}) async {
    typedText = text;
    return true;
  }

  @override
  Future<bool> scroll(String direction, {String? target}) async {
    scrolledDirection = direction;
    return true;
  }

  @override
  Future<bool> pressBack() async {
    pressedBack = true;
    return true;
  }
}

class FakeAiService extends AiService {
  final Stream<String> Function(String message) responder;
  FakeAiService(this.responder);

  @override
  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
    bool voiceResponseStyle = false,
  }) {
    return responder(message);
  }
}

Stream<String> streamOf(String s) async* {
  yield s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAppLauncherService appLauncher;
  late FakeContactsService contacts;
  late FakeCommunicationService communication;
  late FakeAlarmService alarm;
  late FakeSystemControlService systemControl;
  late FakeScreenAutomationService screenAutomation;
  late ActionHandler handler;

  setUp(() {
    appLauncher = FakeAppLauncherService();
    contacts = FakeContactsService();
    communication = FakeCommunicationService();
    alarm = FakeAlarmService();
    systemControl = FakeSystemControlService();
    screenAutomation = FakeScreenAutomationService();
    handler = ActionHandler(
      appLauncher: appLauncher,
      contacts: contacts,
      communication: communication,
      alarm: alarm,
      systemControl: systemControl,
      screenAutomation: screenAutomation,
    );
  });

  test('open_app dispatches to AppLauncherService.openApp', () async {
    final result = await handler.execute(
      AgentAction(action: 'open_app', params: {'app_name': 'YouTube'}, response: ''),
    );
    expect(appLauncher.openedApp, 'YouTube');
    expect(result.success, isTrue);
    expect(result.actionType, 'open_app');
  });

  test('open_url dispatches to AppLauncherService.openUrl', () async {
    await handler.execute(
      AgentAction(action: 'open_url', params: {'url': 'https://example.com'}, response: ''),
    );
    expect(appLauncher.openedUrl, 'https://example.com');
  });

  test('make_call dispatches to CommunicationService.makeCall with contact_name', () async {
    await handler.execute(
      AgentAction(action: 'make_call', params: {'contact_name': 'Mom'}, response: ''),
    );
    expect(communication.calledContact, 'Mom');
  });

  test('send_sms dispatches to CommunicationService.sendSms with contact and message', () async {
    await handler.execute(
      AgentAction(
        action: 'send_sms',
        params: {'contact_name': 'Mom', 'message': 'Running late'},
        response: '',
      ),
    );
    expect(communication.smsContact, 'Mom');
    expect(communication.smsMessage, 'Running late');
  });

  test('search_contact dispatches to ContactsService.searchAndFormat', () async {
    await handler.execute(
      AgentAction(action: 'search_contact', params: {'query': 'Mom'}, response: ''),
    );
    expect(contacts.lastQuery, 'Mom');
  });

  test('set_alarm coerces numeric params and dispatches to AlarmService', () async {
    await handler.execute(
      AgentAction(
        action: 'set_alarm',
        params: {'hour': 7, 'minute': 30},
        response: '',
      ),
    );
    expect(alarm.alarmHour, 7);
    expect(alarm.alarmMinute, 30);
  });

  test('set_volume dispatches to SystemControlService.setVolume', () async {
    await handler.execute(
      AgentAction(action: 'set_volume', params: {'level': 80}, response: ''),
    );
    expect(systemControl.volumeLevel, 80);
  });

  test('set_brightness dispatches to SystemControlService.setBrightness', () async {
    await handler.execute(
      AgentAction(action: 'set_brightness', params: {'level': 40}, response: ''),
    );
    expect(systemControl.brightnessLevel, 40);
  });

  test('read_screen dispatches to ScreenAutomationService.getScreenDescription', () async {
    final result = await handler.execute(
      AgentAction(action: 'read_screen', params: {}, response: ''),
    );
    expect(result.details, 'MOCK SCREEN CONTENT');
  });

  test('click_element reports failure when the element cannot be found', () async {
    screenAutomation.clickShouldSucceed = false;
    final result = await handler.execute(
      AgentAction(action: 'click_element', params: {'text': 'Nonexistent'}, response: ''),
    );
    expect(screenAutomation.clickedText, 'Nonexistent');
    expect(result.details, contains('Could not find'));
  });

  test('press_back dispatches to ScreenAutomationService.pressBack', () async {
    await handler.execute(AgentAction(action: 'press_back', params: {}, response: ''));
    expect(screenAutomation.pressedBack, isTrue);
  });

  test('unknown action falls through to action.response', () async {
    final result = await handler.execute(
      AgentAction(action: 'general_query', params: {}, response: 'Just chatting'),
    );
    expect(result.details, 'Just chatting');
    expect(result.success, isTrue);
  });

  test('a thrown exception is caught and reported as a failed result, not propagated', () async {
    final throwingCommunication = _ThrowingCommunicationService();
    final throwingHandler = ActionHandler(communication: throwingCommunication);
    final result = await throwingHandler.execute(
      AgentAction(action: 'make_call', params: {'contact_name': 'Mom'}, response: ''),
    );
    expect(result.success, isFalse);
    expect(result.details, contains('boom'));
  });

  test('execute_task without an AiService reports a clear error instead of crashing', () async {
    final result = await handler.execute(
      AgentAction(action: 'execute_task', params: {'goal': 'do something'}, response: ''),
    );
    expect(result.success, isTrue);
    expect(result.details, contains('AI service not available'));
  });

  test(
    'execute_task with an AiService but no accessibility service running fails '
    'gracefully instead of crashing (a real scenario: TaskExecutor checks '
    'isServiceRunning() before ever calling the AI)',
    () async {
      final ai = FakeAiService(
        (msg) => streamOf('{"action": "done", "params": {}, "reasoning": "finished", "is_complete": true}'),
      );
      final result = await handler.execute(
        AgentAction(action: 'execute_task', params: {'goal': 'a trivial task'}, response: ''),
        aiService: ai,
      );
      expect(result.success, isTrue);
      expect(result.details, contains('Accessibility service is not enabled'));
    },
  );
}

class _ThrowingCommunicationService extends CommunicationService {
  @override
  Future<String> makeCall({String? contactName, String? phoneNumber}) async {
    throw Exception('boom');
  }
}
