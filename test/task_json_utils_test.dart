import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/task_json_utils.dart';

void main() {
  group('extractTaskActionJson', () {
    test('extracts JSON from a ```json fenced block', () {
      final result = extractTaskActionJson('''
Sure, here you go:
```json
{"action": "click_text", "params": {"text": "OK"}, "is_complete": false}
```
''');
      expect(result, '{"action": "click_text", "params": {"text": "OK"}, "is_complete": false}');
    });

    test('extracts JSON from a plain ``` fenced block', () {
      final result = extractTaskActionJson('''
```
{"action": "wait", "params": {}, "is_complete": false}
```
''');
      expect(result, '{"action": "wait", "params": {}, "is_complete": false}');
    });

    test('falls back to the first { .. last } span when there is no fence', () {
      final result = extractTaskActionJson(
        'Here is the action: {"action": "done", "params": {}, "is_complete": true} — hope that helps!',
      );
      expect(result, '{"action": "done", "params": {}, "is_complete": true}');
    });

    test('returns the trimmed input when no braces are present', () {
      final result = extractTaskActionJson('   no json here   ');
      expect(result, 'no json here');
    });
  });

  group('getNavigationShortcut', () {
    test('returns the dark mode shortcut', () {
      final steps = getNavigationShortcut('turn on dark mode');
      expect(steps, isNotNull);
      expect(steps!.length, 2);
      expect(steps[0].action, 'open_app');
      expect(steps[0].params['app_name'], 'Settings');
      expect(steps[1].params['text'], 'Display');
    });

    test('returns the wifi shortcut for "wi-fi" spelling too', () {
      expect(getNavigationShortcut('turn on wifi'), isNotNull);
      expect(getNavigationShortcut('enable wi-fi'), isNotNull);
    });

    test('matches a known app pattern (case-insensitive)', () {
      final steps = getNavigationShortcut('Open YOUTUBE and search cats');
      expect(steps, isNotNull);
      expect(steps!.single.params['app_name'], 'YouTube');
    });

    test('falls back to a generic "open X" match for an unknown app', () {
      final steps = getNavigationShortcut('open spotify');
      expect(steps, isNotNull);
      expect(steps!.single.params['app_name'], 'Spotify');
    });

    test('returns null when nothing matches', () {
      expect(getNavigationShortcut('do something totally unrelated'), isNull);
    });
  });
}
