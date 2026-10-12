import 'dart:io';

import 'package:almus_ai/data/app_database.dart';
import 'package:almus_ai/data/sqlite_conversation_repository.dart';
import 'package:almus_ai/data/sqlite_memory_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'memory_repository_contract.dart';

Future<AppDatabase> _openMemory() =>
    AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);

void main() {
  sqfliteFfiInit();

  AppDatabase? shared;
  runMemoryRepositoryContract(
    'SQLite',
    () async {
      shared = await _openMemory();
      return SqliteMemoryRepository(shared!);
    },
    dispose: () async {
      await shared?.close();
      shared = null;
    },
  );

  group('memory schema', () {
    test('migration 2 creates the memory tables', () async {
      final AppDatabase database = await _openMemory();
      final List<Map<String, Object?>> objects = await database.db
          .rawQuery("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
      final Set<String> names =
          objects.map((Map<String, Object?> r) => r['name']! as String).toSet();
      expect(
        names,
        containsAll(<String>[
          'memories',
          'memory_prefs',
          'memory_conversation_flags',
          'idx_memories_status',
        ]),
      );
      final List<Map<String, Object?>> columns =
          await database.db.rawQuery('PRAGMA table_info(memories)');
      expect(
        columns.map((Map<String, Object?> c) => c['name']),
        <String>[
          'id',
          'category',
          'text',
          'created_at',
          'updated_at',
          'source_conversation_id',
          'status',
        ],
      );
      await database.close();
    });

    test('the database rejects unknown categories and statuses', () async {
      final AppDatabase database = await _openMemory();
      Future<void> insert(String id, String category, String status) =>
          database.db.insert('memories', <String, Object?>{
            'id': id,
            'category': category,
            'text': 'x',
            'created_at': 1,
            'updated_at': 1,
            'status': status,
          });
      await insert('ok', 'fact', 'confirmed');
      expect(insert('bad1', 'secrets', 'confirmed'), throwsA(isA<Exception>()));
      expect(insert('bad2', 'fact', 'pending'), throwsA(isA<Exception>()));
      await database.close();
    });

    test('upgrading a version 1 database keeps chats and adds memory', () async {
      final Directory dir = Directory.systemTemp.createTempSync('almus_mem_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = p.join(dir.path, 'upgrade.db');

      final AppDatabase v1 = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
        migrations: kMigrations.where((Migration m) => m.version == 1).toList(),
      );
      await SqliteConversationRepository(v1).createConversation(id: 'c1', title: 'Keep me');
      await v1.close();

      final AppDatabase v2 = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
      final List<Map<String, Object?>> version = await v2.db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, kMigrations.last.version);
      expect((await SqliteConversationRepository(v2).listConversations()).single.title, 'Keep me');

      final SqliteMemoryRepository repo = SqliteMemoryRepository(v2);
      await repo.insert(memoryItem('a', text: 'Persisted memory'));
      await v2.close();

      final AppDatabase reopened = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
      final SqliteMemoryRepository again = SqliteMemoryRepository(reopened);
      expect((await again.get('a'))!.text, 'Persisted memory');
      await reopened.close();
    });

    test('a closed database reports a safe StorageException', () async {
      final AppDatabase database = await _openMemory();
      final SqliteMemoryRepository repo = SqliteMemoryRepository(database);
      await database.close();
      try {
        await repo.insert(memoryItem('a', text: 'private memory text'));
        fail('Expected a StorageException');
      } on StorageException catch (e) {
        expect(e.message, isNot(contains('private')));
      }
    });
  });
}
