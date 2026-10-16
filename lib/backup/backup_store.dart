import 'backup_models.dart';

/// How an import treats data that is already on the phone.
enum ImportMode {
  /// Keep everything that is there; add what is missing. Records that already
  /// exist (same id) are never overwritten.
  merge,

  /// Replace the conversations, messages and memories (whichever are selected)
  /// with the contents of the backup. Needs explicit confirmation in the UI.
  replace,
}

/// What the user chose to import.
class ImportOptions {
  const ImportOptions({
    this.mode = ImportMode.merge,
    this.conversations = true,
    this.memories = true,
    this.settings = true,
  });

  final ImportMode mode;
  final bool conversations;
  final bool memories;
  final bool settings;

  ImportOptions copyWith({
    ImportMode? mode,
    bool? conversations,
    bool? memories,
    bool? settings,
  }) {
    return ImportOptions(
      mode: mode ?? this.mode,
      conversations: conversations ?? this.conversations,
      memories: memories ?? this.memories,
      settings: settings ?? this.settings,
    );
  }
}

/// Number of stored records.
class StoreCounts {
  const StoreCounts({
    this.conversations = 0,
    this.messages = 0,
    this.memories = 0,
  });

  final int conversations;
  final int messages;
  final int memories;

  @override
  bool operator ==(Object other) =>
      other is StoreCounts &&
      other.conversations == conversations &&
      other.messages == messages &&
      other.memories == memories;

  @override
  int get hashCode => Object.hash(conversations, messages, memories);

  @override
  String toString() =>
      'StoreCounts(conversations: $conversations, messages: $messages, memories: $memories)';
}

/// What an import would do (preview) or did (result).
class ImportSummary {
  const ImportSummary({
    this.newConversations = 0,
    this.mergedConversations = 0,
    this.duplicateConversations = 0,
    this.newMessages = 0,
    this.duplicateMessages = 0,
    this.conflictingMessages = 0,
    this.newMemories = 0,
    this.duplicateMemories = 0,
    this.settingsApplied = false,
    this.removed = const StoreCounts(),
  });

  /// Conversations that did not exist yet.
  final int newConversations;

  /// Existing conversations that receive messages they were missing.
  final int mergedConversations;

  /// Conversations that are already fully present.
  final int duplicateConversations;

  final int newMessages;
  final int duplicateMessages;

  /// Messages skipped because their id already belongs to a different
  /// conversation. Existing data wins; nothing is overwritten.
  final int conflictingMessages;

  final int newMemories;
  final int duplicateMemories;
  final bool settingsApplied;

  /// Records deleted by a replace (what the user confirmed).
  final StoreCounts removed;

  int get totalChanges =>
      newConversations + newMessages + newMemories + (settingsApplied ? 1 : 0);
}

/// Progress of a running import.
class ImportProgress {
  const ImportProgress(this.stage, this.done, this.total);

  final String stage;
  final int done;
  final int total;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

typedef ImportProgressCallback = void Function(ImportProgress progress);

/// Reads data for export and applies imports. An import is all-or-nothing:
/// either every change is stored or none is.
abstract class BackupStore {
  Future<StoreCounts> counts();

  /// Reads stored data. [conversationIds] limits which conversations are read
  /// (null = all). [settings] adds the stored memory switches.
  Future<BackupBundle> read({
    Set<String>? conversationIds,
    bool conversations = true,
    bool memories = true,
    bool settings = false,
  });

  /// Dry run: reports what [apply] would do. Changes nothing.
  Future<ImportSummary> plan(BackupBundle bundle, ImportOptions options);

  /// Applies [bundle] inside one database transaction. On any failure every
  /// change is rolled back and a [BackupException] is thrown.
  Future<ImportSummary> apply(
    BackupBundle bundle,
    ImportOptions options, {
    ImportProgressCallback? onProgress,
  });
}
