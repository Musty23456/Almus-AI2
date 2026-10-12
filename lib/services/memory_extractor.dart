import '../models/memory_item.dart';
import 'memory_text.dart';
import 'sensitive_filter.dart';

/// A memory Almus proposes. It is only a suggestion until the user confirms it.
class MemorySuggestion {
  const MemorySuggestion(this.category, this.text);

  final MemoryCategory category;
  final String text;
}

class _Pattern {
  _Pattern(this.category, String pattern)
      : regex = RegExp(
          '^(?:(?:also|and|so|well|btw|by the way),?\\s+)?(?:$pattern)',
          caseSensitive: false,
          unicode: true,
        );

  final MemoryCategory category;
  final RegExp regex;
}

final List<_Pattern> _patterns = <_Pattern>[
  _Pattern(MemoryCategory.profile,
      r"my name is\s+\S+|call me\s+\S+|sunana\s+\S+|i(?:'m| am) called\s+\S+"),
  _Pattern(MemoryCategory.profile,
      r"i work (?:as|at|for|in)\s+\S+|i(?:'m| am) (?:a|an) (?:student|teacher|developer|engineer|designer|doctor|nurse|farmer|lawyer|accountant|programmer|writer|entrepreneur|trader|manager|driver|artist|researcher|freelancer|beginner)\b"),
  _Pattern(MemoryCategory.profile,
      r"i live in\s+\S+|i(?:'m| am) (?:from|based in)\s+\S+"),
  _Pattern(MemoryCategory.preference,
      r"i (?:really |also |usually |generally )?(?:prefer|dislike|hate)\b|i (?:always|usually) \S+|i like (?:it when|answers|explanations|you to|short|simple|detailed)|please (?:always|never)\s+\S+|(?:always|never) (?:answer|reply|respond|explain|use|give)\b"),
  _Pattern(MemoryCategory.learning,
      r"i(?:'m| am|'ve been| have been) (?:learning|studying|practi[cs]ing|taking a course)\b|ina koyon\s+\S+|na fara koyon\s+\S+"),
  _Pattern(MemoryCategory.project,
      r"i(?:'m| am|'ve been| have been) (?:working on|building|developing|creating|designing|writing)\s+\S+|my (?:project|app|startup|business|website|thesis|book)\b|ina aiki (?:a kan|akan)\s+\S+|ina gina\s+\S+"),
  _Pattern(MemoryCategory.goal,
      r"my (?:main |long[- ]term |short[- ]term )?(?:goal|plan|aim|dream) is\b|i (?:plan|aim|intend) to\s+\S+|i(?:'m| am) planning to\s+\S+|burina shi ne|ina shirin\s+\S+"),
];

final List<RegExp> _explicit = <RegExp>[
  RegExp(
    r"^(?:please\s+)?(?:remember|note|keep in mind|don'?t forget)\s+that\s+(.+)$",
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r"^(?:please\s+)?(?:remember|note)\s*[:,]\s*(.+)$",
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r"^(?:please\s+)?(?:remember|note)\s+((?:i|i'm|i am|my|we|our)\b.+)$",
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r"^(?:ka|ki)\s+tuna(?:\s+cewa)?[:,]?\s+(.+)$",
    caseSensitive: false,
    unicode: true,
  ),
];

final RegExp _sentence = RegExp(r'[^.!?\n]+[.!?]*');

MemoryCategory _categoryFor(String content) {
  for (final _Pattern pattern in _patterns) {
    if (pattern.regex.hasMatch(content)) return pattern.category;
  }
  return MemoryCategory.fact;
}

String _stripEnd(String text) =>
    text.replaceAll(RegExp(r'[\s.!,;:]+$'), '').trim();

/// Looks for things the user said about themselves that may be worth keeping.
///
/// This runs on the phone with simple patterns and no network. It only
/// proposes; nothing is saved until the user confirms. Questions, sensitive
/// topics and secrets are never proposed.
List<MemorySuggestion> extractMemorySuggestions(String message, {int max = 2}) {
  final List<MemorySuggestion> found = <MemorySuggestion>[];
  for (final RegExpMatch match in _sentence.allMatches(message)) {
    if (found.length >= max) break;
    final String sentence = cleanMemoryText(match.group(0) ?? '');
    if (sentence.isEmpty || sentence.endsWith('?')) continue;

    MemoryCategory? category;
    String? text;

    for (final RegExp explicit in _explicit) {
      final RegExpMatch? m = explicit.firstMatch(sentence);
      if (m != null) {
        text = _stripEnd(m.group(1) ?? '');
        category = _categoryFor(text);
        break;
      }
    }
    if (text == null) {
      for (final _Pattern pattern in _patterns) {
        if (pattern.regex.hasMatch(sentence)) {
          text = _stripEnd(sentence);
          category = pattern.category;
          break;
        }
      }
    }
    if (text == null || category == null) continue;
    final String value = text;
    if (value.length < 8 || value.length > 300) continue;
    if (value.split(' ').length < 3) continue;
    if (checkSensitivity(value).level != Sensitivity.none) continue;
    if (found.any((MemorySuggestion s) => isDuplicateMemoryText(s.text, value))) {
      continue;
    }
    found.add(MemorySuggestion(category, value));
  }
  return found;
}

/// Builds an editable, extractive summary of a chat from the user's own
/// messages. It does not use AI and may miss things; the user reviews and
/// edits it before it is saved.
String draftConversationSummary({
  required String title,
  required List<String> userMessages,
  required int messageCount,
  required DateTime date,
}) {
  String short(String text, int limit) {
    final String clean = cleanMemoryText(text);
    if (clean.length <= limit) return clean;
    return '${clean.substring(0, limit).trimRight()}…';
  }

  final String month = const <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ][date.month - 1];
  final StringBuffer out = StringBuffer(
    'Chat "${short(title, 60)}" (${date.day} $month ${date.year}, $messageCount messages).',
  );
  final List<String> messages =
      userMessages.where((String m) => cleanMemoryText(m).isNotEmpty).toList();
  if (messages.isEmpty) return out.toString();
  out.write(' The user first wrote: ${short(messages.first, 140)}');
  if (messages.length > 1) {
    out.write(' Most recently: ${short(messages.last, 140)}');
  }
  return out.toString();
}
