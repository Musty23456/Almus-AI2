/// Longest memory text the app accepts (characters).
const int kMaxMemoryChars = 600;

/// The kinds of personal memory Almus can keep.
enum MemoryCategory {
  profile('profile', 'Personal profile'),
  preference('preference', 'Preferences'),
  learning('learning', 'Learning progress'),
  project('project', 'Projects'),
  goal('goal', 'Goals and plans'),
  fact('fact', 'Approved facts'),
  summary('summary', 'Conversation summaries');

  const MemoryCategory(this.key, this.label);

  /// Stable value stored in the database. Never change an existing key.
  final String key;

  /// Name shown to the user.
  final String label;

  static MemoryCategory? fromKey(String key) {
    for (final MemoryCategory category in MemoryCategory.values) {
      if (category.key == key) return category;
    }
    return null;
  }
}

/// Whether the user has approved a memory.
///
/// * [confirmed]: the user wrote it, edited it or tapped Save/Confirm.
/// * [suggested]: Almus proposed it. It is never used in AI requests until
///   the user confirms it.
enum MemoryStatus {
  confirmed('confirmed'),
  suggested('suggested');

  const MemoryStatus(this.key);

  final String key;

  static MemoryStatus? fromKey(String key) {
    for (final MemoryStatus status in MemoryStatus.values) {
      if (status.key == key) return status;
    }
    return null;
  }
}

/// One saved memory record.
class MemoryItem {
  const MemoryItem({
    required this.id,
    required this.category,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.sourceConversationId,
    this.status = MemoryStatus.confirmed,
  });

  final String id;
  final MemoryCategory category;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The chat this memory came from, when known.
  final String? sourceConversationId;

  final MemoryStatus status;

  bool get isConfirmed => status == MemoryStatus.confirmed;
  bool get isSuggested => status == MemoryStatus.suggested;

  MemoryItem copyWith({
    MemoryCategory? category,
    String? text,
    DateTime? updatedAt,
    MemoryStatus? status,
  }) {
    return MemoryItem(
      id: id,
      category: category ?? this.category,
      text: text ?? this.text,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceConversationId: sourceConversationId,
      status: status ?? this.status,
    );
  }
}
