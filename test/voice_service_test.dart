import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/voice_service.dart';

void main() {
  group('VoiceService.sanitizeForSpeech', () {
    test('strips fenced code blocks entirely', () {
      final result = VoiceService.sanitizeForSpeech(
        'Here you go:\n```dart\nprint("hi");\n```\nDone.',
      );
      expect(result, 'Here you go: Done.');
    });

    test('unwraps inline code spans', () {
      expect(
        VoiceService.sanitizeForSpeech('Run `flutter test` first.'),
        'Run flutter test first.',
      );
    });

    test('replaces markdown links with their link text', () {
      expect(
        VoiceService.sanitizeForSpeech('See [the docs](https://example.com/x) for more.'),
        'See the docs for more.',
      );
    });

    test('strips bare URLs', () {
      expect(
        VoiceService.sanitizeForSpeech('Visit https://example.com/path?q=1 now.'),
        'Visit now.',
      );
    });

    test('strips bold/italic/strikethrough markers', () {
      expect(
        VoiceService.sanitizeForSpeech('This is **very** *important* and ~~wrong~~.'),
        'This is very important and wrong.',
      );
    });

    test('strips list/header markers and collapses newlines to spaces', () {
      expect(
        VoiceService.sanitizeForSpeech('# Title\n- item one\n- item two'),
        'Title item one item two',
      );
    });

    test('strips emoji', () {
      expect(
        VoiceService.sanitizeForSpeech('Task complete! \u{2705}\u{1F389}'),
        'Task complete!',
      );
    });

    test('leaves plain speakable text unchanged', () {
      const plain = 'The task finished successfully in three steps.';
      expect(VoiceService.sanitizeForSpeech(plain), plain);
    });
  });
}
