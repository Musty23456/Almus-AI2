const int kMaxTitleLength = 80;
const int kAutoTitleLength = 40;
const String kDefaultTitle = 'New chat';

/// A saved conversation (chat thread).
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.preview = '',
  });

  final String id;
  final String title;
  final DateTime createdAt;

  /// Time of the most recent message (used for ordering).
  final DateTime updatedAt;

  /// Number of stored messages (filled in by list queries).
  final int messageCount;

  /// Text of the latest message (filled in by list queries).
  final String preview;

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    int? messageCount,
    String? preview,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageCount: messageCount ?? this.messageCount,
      preview: preview ?? this.preview,
    );
  }
}

String _safeSubstring(String text, int length) {
  if (text.length <= length) return text;
  int end = length;
  // Do not cut an emoji (surrogate pair) in half.
  final int unit = text.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end -= 1;
  return text.substring(0, end);
}

/// Collapses whitespace and limits length. Returns null if nothing is left.
String? cleanTitle(String raw) {
  final String collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return null;
  return _safeSubstring(collapsed, kMaxTitleLength).trimRight();
}

/// Builds a short automatic title from the first message of a chat.
String titleFromMessage(String text) {
  final String cleaned = cleanTitle(text) ?? kDefaultTitle;
  if (cleaned.length <= kAutoTitleLength) return cleaned;
  return '${_safeSubstring(cleaned, kAutoTitleLength).trimRight()}…';
}
