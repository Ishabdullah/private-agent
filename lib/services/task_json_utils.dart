import '../models/saved_skill.dart';

/// Extract JSON safely even if wrapped in markdown or conversational text.
String extractTaskActionJson(String text) {
  // 1. Try to find a markdown json code block
  final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
  final match = codeBlockRegex.firstMatch(text);
  if (match != null) {
    return match.group(1)!;
  }

  // 2. Fallback (P1-7 audit fix): extract the first balanced { ... } block to avoid trailing conversation braces breaking parsing
  final startIndex = text.indexOf('{');
  if (startIndex == -1) return text.trim();

  int braceCount = 0;
  int endIndex = -1;
  for (int i = startIndex; i < text.length; i++) {
    if (text[i] == '{') braceCount++;
    if (text[i] == '}') braceCount--;
    if (braceCount == 0) {
      endIndex = i;
      break;
    }
  }

  if (endIndex != -1) {
    return text.substring(startIndex, endIndex + 1);
  }

  return text.trim();
}

/// Returns predefined navigation steps for common tasks, or null if the goal
/// doesn't match any known shortcut.
List<ActionStep>? getNavigationShortcut(String goal) {
  final lower = goal.toLowerCase();

  if (lower.contains('dark mode') || lower.contains('dark theme')) {
    return [
      ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
      ActionStep(action: 'click_text', params: {'text': 'Display'}),
    ];
  }
  if (lower.contains('wifi') || lower.contains('wi-fi')) {
    return [
      ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
      ActionStep(
        action: 'click_text',
        params: {'text': 'Network & internet'},
      ),
    ];
  }
  if (lower.contains('bluetooth')) {
    return [
      ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
      ActionStep(action: 'click_text', params: {'text': 'Connected devices'}),
    ];
  }

  final appPatterns = <String, List<String>>{
    'Settings': ['settings', 'brightness', 'display', 'notification'],
    'Play Store': [
      'play store',
      'playstore',
      'download',
      'install app',
      'google play',
    ],
    'YouTube': ['youtube'],
    'WhatsApp': ['whatsapp'],
    'Chrome': ['chrome', 'browse', 'search google'],
    'Camera': ['camera', 'take a photo', 'take photo', 'take a picture'],
    'Gallery': ['gallery', 'photos'],
    'Messages': ['message', 'sms', 'text to'],
    'Phone': ['call', 'dial'],
    'Gmail': ['gmail', 'email'],
    'Maps': ['maps', 'navigate to', 'directions'],
    'Clock': ['alarm', 'timer', 'stopwatch'],
    'Calculator': ['calculator', 'calculate', 'calc'],
  };

  for (final entry in appPatterns.entries) {
    for (final keyword in entry.value) {
      if (lower.contains(keyword)) {
        return [
          ActionStep(action: 'open_app', params: {'app_name': entry.key}),
        ];
      }
    }
  }

  // Generic fallback for "open X"
  final openMatch = RegExp(r'^open\s+([a-zA-Z0-9]+)').firstMatch(lower);
  if (openMatch != null) {
    String app = openMatch.group(1)!;
    app = app[0].toUpperCase() + app.substring(1);
    return [
      ActionStep(action: 'open_app', params: {'app_name': app}),
    ];
  }

  return null;
}
