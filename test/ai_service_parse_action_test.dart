import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  late AiService service;

  setUp(() {
    service = AiService();
  });

  test('parses a plain JSON action response', () {
    final action = service.parseAction(
      '{"action": "open_app", "params": {"app_name": "YouTube"}, "response": "Opening YouTube"}',
    );

    expect(action, isNotNull);
    expect(action!.action, 'open_app');
    expect(action.params['app_name'], 'YouTube');
    expect(action.response, 'Opening YouTube');
  });

  test('parses an action response wrapped in a markdown code fence', () {
    final action = service.parseAction('''
```json
{"action": "set_volume", "params": {"level": 50}, "response": "Setting volume"}
```
''');

    expect(action, isNotNull);
    expect(action!.action, 'set_volume');
    expect(action.params['level'], 50);
  });

  test('parses an action response wrapped in a plain code fence (no "json" tag)', () {
    final action = service.parseAction('''
```
{"action": "press_back", "params": {}, "response": "Going back"}
```
''');

    expect(action, isNotNull);
    expect(action!.action, 'press_back');
  });

  test('recovers from a response missing its closing brace', () {
    final action = service.parseAction(
      '{"action": "read_screen", "params": {}, "response": "Reading screen"',
    );

    expect(action, isNotNull);
    expect(action!.action, 'read_screen');
  });

  test('returns null for plain conversational text', () {
    final action = service.parseAction(
      "Sure, I'd be happy to help you with that!",
    );

    expect(action, isNull);
  });

  test('returns null for text that merely mentions JSON-like content without an "action" key', () {
    final action = service.parseAction(
      '{"note": "this is not an action payload"}',
    );

    expect(action, isNull);
  });

  test('returns null for malformed JSON that cannot be recovered', () {
    final action = service.parseAction('{"action": "open_app", params: }');

    expect(action, isNull);
  });
}
