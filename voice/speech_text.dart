/// Prepares assistant text for text-to-speech.
///
/// Only the visible words are spoken. Code blocks, links, markdown symbols
/// and other technical clutter are removed or shortened so the voice does not
/// read "asterisk asterisk" or a long URL.
class SpeechText {
  const SpeechText._();

  /// Hard cap so one very long reply cannot lock the speaker for minutes.
  /// Android's TTS engine also limits one request to about 4000 characters.
  static const int maxChars = 3500;

  static String clean(String input) {
    String t = input;
    // Fenced code blocks: not useful to hear.
    t = t.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ');
    // Inline code: keep the words, drop the backticks.
    t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (Match m) => m.group(1) ?? '');
    // Markdown links [text](url) -> text.
    t = t.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (Match m) => m.group(1) ?? '',
    );
    // Bare URLs.
    t = t.replaceAll(RegExp(r'https?://\S+'), ' ');
    // Horizontal rules (---, ***) are not words.
    t = t.replaceAll(RegExp(r'^\s*(?:[-*_]\s*){3,}$', multiLine: true), '');
    // Headings, quote markers and list bullets at line start.
    t = t.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    // Emphasis: keep the words, drop the markers.
    t = t.replaceAllMapped(
      RegExp(r'(\*\*|__)(.+?)\1'),
      (Match m) => m.group(2) ?? '',
    );
    t = t.replaceAllMapped(
      RegExp(r'\*(\S(?:[^*]*?\S)?)\*'),
      (Match m) => m.group(1) ?? '',
    );
    // Leftover markdown characters (underscores in names read as spaces).
    t = t.replaceAll(RegExp(r'[*_~#|]+'), ' ');
    // Collapse whitespace.
    t = t.replaceAll(RegExp(r'\s+'), ' ').replaceAll(' ,', ',').trim();
    if (t.length > maxChars) {
      t = _cut(t);
    }
    return t;
  }

  static String _cut(String t) {
    final String head = t.substring(0, maxChars);
    final int end = head.lastIndexOf(RegExp(r'[.!?]'));
    return end > maxChars ~/ 2 ? head.substring(0, end + 1) : head;
  }
}
