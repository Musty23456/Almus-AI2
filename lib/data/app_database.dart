import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'storage_exception.dart';

/// One step of the schema history. Add a new [Migration] with a higher
/// version number to change the schema; never edit an old one.
class Migration {
  const Migration(this.version, this.statements);

  final int version;
  final List<String> statements;
}

/// Schema history. Version 1 creates conversations and messages.
/// Version 2 adds personal memories (Phase 4).
const List<Migration> kMigrations = <Migration>[
  Migration(1, <String>[
    '''
CREATE TABLE conversations (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''',
    '''
CREATE TABLE messages (
  id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'error')),
  engine TEXT NOT NULL DEFAULT 'DEMO',
  FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
)''',
    'CREATE INDEX idx_messages_conversation ON messages (conversation_id, created_at)',
    'CREATE INDEX idx_conversations_updated ON conversations (updated_at)',
  ]),
  Migration(2, <String>[
    '''
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('profile', 'preference', 'learning', 'project', 'goal', 'fact', 'summary')),
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  source_conversation_id TEXT,
  status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'suggested'))
)''',
    'CREATE INDEX idx_memories_status ON memories (status, updated_at)',
    'CREATE TABLE memory_prefs (name TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
    'CREATE TABLE memory_conversation_flags (conversation_id TEXT PRIMARY KEY NOT NULL)',
  ]),
];

/// Applies every migration with `from < version <= to`, in order.
Future<void> runMigrations(
  DatabaseExecutor db,
  int from,
  int to, [
  List<Migration> migrations = kMigrations,
]) async {
  final List<Migration> ordered = List<Migration>.of(migrations)
    ..sort((Migration a, Migration b) => a.version.compareTo(b.version));
  for (final Migration migration in ordered) {
    if (migration.version > from && migration.version <= to) {
      for (final String statement in migration.statements) {
        await db.execute(statement);
      }
    }
  }
}

/// Owns the SQLite database file. Contains no UI code and no credentials.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const String fileName = 'almus_ai.db';

  /// Opens (and creates or upgrades) the database.
  /// Pass a [factory] and [path] in tests (for example `databaseFactoryFfi`).
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
    List<Migration> migrations = kMigrations,
  }) async {
    final DatabaseFactory dbFactory = factory ?? databaseFactory;
    try {
      final String dbPath =
          path ?? p.join(await dbFactory.getDatabasesPath(), fileName);
      final int version = migrations
          .map((Migration m) => m.version)
          .reduce((int a, int b) => a > b ? a : b);
      final Database db = await dbFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: version,
          onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (Database db, int newVersion) =>
              runMigrations(db, 0, newVersion, migrations),
          onUpgrade: (Database db, int oldVersion, int newVersion) =>
              runMigrations(db, oldVersion, newVersion, migrations),
        ),
      );
      return AppDatabase._(db);
    } on DatabaseException {
      throw const StorageException('The local database could not be opened.');
    }
  }

  Future<void> close() async {
    try {
      await db.close();
    } on DatabaseException {
      // Closing is best effort.
    }
  }
}
