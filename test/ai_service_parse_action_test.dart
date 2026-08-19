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

  test('parses a <tool_call> tag action with no params', () {
    final action = service.parseAction('<tool_call>read_screen</tool_call>');

    expect(action, isNotNull);
    expect(action!.action, 'read_screen');
    expect(action.params, isEmpty);
  });

  test('parses a <tool_call> tag action with arg_key/arg_value params', () {
    final action = service.parseAction(
      "I'll send that text to Mom right away."
      '<tool_call>send_sms'
      '<arg_key>contact_name</arg_key><arg_value>Mom</arg_value>'
      '<arg_key>message</arg_key><arg_value>I love you</arg_value>'
      '</tool_call>',
    );

    expect(action, isNotNull);
    expect(action!.action, 'send_sms');
    expect(action.params['contact_name'], 'Mom');
    expect(action.params['message'], 'I love you');
    expect(action.response, "I'll send that text to Mom right away.");
  });

  test('coerces numeric-looking <tool_call> param values to num', () {
    final action = service.parseAction(
      '<tool_call>set_volume<arg_key>level</arg_key><arg_value>50</arg_value></tool_call>',
    );

    expect(action, isNotNull);
    expect(action!.params['level'], 50);
    expect(action.params['level'], isA<num>());
  });
}
