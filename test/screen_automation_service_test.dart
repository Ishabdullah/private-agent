import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/screen_automation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.privateagent/accessibility');
  late ScreenAutomationService service;

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    service = ScreenAutomationService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('simple boolean passthrough methods', () {
    test('clickByText returns true when the native side reports success', () async {
      setHandler((call) async {
        expect(call.method, 'clickByText');
        expect(call.arguments, {'text': 'Submit'});
        return true;
      });

      expect(await service.clickByText('Submit'), isTrue);
    });

    test('clickByText returns false (not throws) when the channel errors', () async {
      setHandler((call) async {
        throw PlatformException(code: 'ERR', message: 'boom');
      });

      expect(await service.clickByText('Submit'), isFalse);
    });

    test('pressBack/pressHome/scroll return false when native returns null', () async {
      setHandler((call) async => null);

      expect(await service.pressBack(), isFalse);
      expect(await service.pressHome(), isFalse);
      expect(await service.scroll('down'), isFalse);
    });
  });

  group('dumpScreen', () {
    test('returns an empty list and does not throw when the channel errors', () async {
      setHandler((call) async {
        throw PlatformException(code: 'ERR', message: 'boom');
      });

      expect(await service.dumpScreen(), isEmpty);
    });

    test('converts native maps into List<Map<String, dynamic>>', () async {
      setHandler((call) async {
        if (call.method == 'dumpScreen') {
          return [
            {'index': 0, 'text': 'Hello', 'isClickable': true},
          ];
        }
        return null;
      });

      final nodes = await service.dumpScreen();
      expect(nodes, [
        {'index': 0, 'text': 'Hello', 'isClickable': true},
      ]);
    });
  });

  group('getScreenDescription', () {
    test('reports an unreadable screen when there are no nodes', () async {
      setHandler((call) async {
        if (call.method == 'dumpScreen') return [];
        return null;
      });

      final description = await service.getScreenDescription();
      expect(description, contains('Could not read screen'));
    });

    test('renders visible/interactive nodes with tags and bounds, skips empty non-interactive ones', () async {
      setHandler((call) async {
        if (call.method == 'dumpScreen') {
          return [
            {
              'index': 0,
              'text': 'Login',
              'className': 'android.widget.Button',
              'isClickable': true,
              'bounds': {'left': 10, 'top': 20, 'right': 110, 'bottom': 60},
            },
            {'index': 1, 'text': '', 'isClickable': false, 'isEditable': false, 'isScrollable': false},
          ];
        }
        if (call.method == 'getCurrentPackage') return 'com.example.app';
        return null;
      });

      final description = await service.getScreenDescription();
      expect(description, contains('Current app: com.example.app'));
      expect(description, contains('"Login"'));
      expect(description, contains('{clickable}'));
      // The empty, non-interactive second node must be skipped entirely.
      expect(description, isNot(contains('[1]')));
    });
  });

  group('getCompressedScreenDescription', () {
    test('filters out clock/status-bar noise nodes', () async {
      setHandler((call) async {
        if (call.method == 'dumpScreen') {
          return [
            {'index': 0, 'text': '10:32', 'isClickable': false, 'isEditable': false, 'isScrollable': false},
            {'index': 1, 'text': '87 percent', 'isClickable': false, 'isEditable': false, 'isScrollable': false},
            {'index': 2, 'text': 'Search', 'className': 'android.widget.EditText', 'isEditable': true},
          ];
        }
        return null;
      });

      final description = await service.getCompressedScreenDescription('search for cats');
      expect(description, isNot(contains('10:32')));
      expect(description, isNot(contains('percent')));
      expect(description, contains('Search'));
      expect(description, contains('input'));
    });

    test('marks nodes matching task keywords with a target marker', () async {
      setHandler((call) async {
        if (call.method == 'dumpScreen') {
          return [
            {'index': 0, 'text': 'Coffee shop nearby', 'className': 'android.widget.TextView'},
          ];
        }
        return null;
      });

      final description = await service.getCompressedScreenDescription('find coffee shop');
      expect(description, contains('*'));
    });
  });
}
