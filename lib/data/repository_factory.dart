import '../backup/backup_store.dart';
import '../backup/sqlite_backup_store.dart';
import 'app_database.dart';
import 'conversation_repository.dart';
import 'memory_conversation_repository.dart';
import 'memory_repository.dart';
import 'sqlite_conversation_repository.dart';
import 'sqlite_memory_repository.dart';
import 'volatile_memory_repository.dart';

/// The repositories to use plus whether they survive app restarts.
class RepositoryOpenResult {
  const RepositoryOpenResult(
    this.repository, {
    required this.persistent,
    required this.memory,
    this.backupStore,
  });

  final ConversationRepository repository;
  final bool persistent;

  /// Personal memories (Phase 4). Lives in the same database file.
  final MemoryRepository memory;

  /// Phase 2: backup / restore of the stored data. Null when the database
  /// could not be opened (there is nothing persistent to back up then).
  final BackupStore? backupStore;
}

/// Opens the SQLite database. If that fails for any reason, the app keeps
/// working with in-memory storage and tells the user nothing is saved.
Future<RepositoryOpenResult> openDefaultRepository() async {
  try {
    final AppDatabase database = await AppDatabase.open();
    return RepositoryOpenResult(
      SqliteConversationRepository(database),
      persistent: true,
      memory: SqliteMemoryRepository(database),
      backupStore: SqliteBackupStore(database),
    );
  } on Exception {
    return RepositoryOpenResult(
      MemoryConversationRepository(),
      persistent: false,
      memory: VolatileMemoryRepository(),
    );
  }
}
