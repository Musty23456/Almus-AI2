import 'dart:io';

import 'package:almus_ai/data/app_database.dart';
import 'package:almus_ai/data/sqlite_conversation_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'repository_contract.dart';

Future<AppDatabase> _openMemory() =>
    AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);

void main() {
  sqfliteFfiInit();

  // The same behaviour tests that the in-memory repository passes.
  runRepositoryContract('SQLite', () async {
    return SqliteConversationRepository(await _openMemory());
  });

  group('database creation and migrations', () {
    test('creates tables, indexes, version and foreign keys', () async {
      final AppDatabase database = await _openMemory();
      final List<Map<String, Object?>> objects = await database.db
          .rawQuery("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
      final Set<String> names = objects.map((Map<String, Object?> r) => r['name']! as String).toSet();

      expect(names, containsAll(<String>[
        'conversations',
        'messages',
        'idx_messages_conversation',
        'idx_conversations_updated',
      ]));
      final List<Map<String, Object?>> version = await database.db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, kMigrations.last.version);
      final List<Map<String, Object?>> fk = await database.db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first.values.first, 1);

      final List<Map<String, Object?>> columns = await database.db.rawQuery('PRAGMA table_info(messages)');
      expect(
        columns.map((Map<String, Object?> c) => c['name']),
        <String>['id', 'conversation_id', 'role', 'content', 'created_at', 'status', 'engine'],
      );
      await database.close();
    });

    test('the database itself rejects roles other than user/assistant', () async {
      final AppDatabase database = await _openMemory();
      await database.db.insert('conversations', <String, Object?>{
        'id': 'c1', 'title': 't', 'created_at': 1, 'updated_at': 1,
      });
      Future<void> insert(String role) => database.db.insert('messages', <String, Object?>{
            'id': 'm-$role', 'conversation_id': 'c1', 'role': role,
            'content': 'x', 'created_at': 1,
          });
      await insert('user');
      await insert('assistant');
      expect(insert('system'), throwsA(isA<DatabaseException>()));
      await database.close();
    });

    test('foreign keys cascade deletes to messages', () async {
      final AppDatabase database = await _openMemory();
      final SqliteConversationRepository repo = SqliteConversationRepository(database);
      await repo.createConversation(id: 'c1');
      await repo.addMessage(msg('m1', 'c1', 'hello'));
      await database.db.delete('conversations', where: 'id = ?', whereArgs: <Object?>['c1']);
      expect(await database.db.query('messages'), isEmpty);
      await database.close();
    });

    test('runMigrations applies only the versions in range', () async {
      final AppDatabase database = await _openMemory();
      const List<Migration> extra = <Migration>[
        Migration(2, <String>['CREATE TABLE extra_two (id INTEGER)']),
        Migration(3, <String>['CREATE TABLE extra_three (id INTEGER)']),
      ];
      await runMigrations(database.db, 1, 2, extra);
      final List<Map<String, Object?>> rows = await database.db
          .rawQuery("SELECT name FROM sqlite_master WHERE name LIKE 'extra_%'");
      expect(rows.map((Map<String, Object?> r) => r['name']), <String>['extra_two']);
      await database.close();
    });

    test('upgrades an existing database file without losing data', () async {
      final Directory dir = Directory.systemTemp.createTempSync('almus_db_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = p.join(dir.path, 'upgrade.db');

      final AppDatabase v1 = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
        migrations: kMigrations.where((Migration m) => m.version == 1).toList(),
      );
      final SqliteConversationRepository repo1 = SqliteConversationRepository(v1);
      await repo1.createConversation(id: 'c1', title: 'Keep me');
      await repo1.addMessage(msg('m1', 'c1', 'still here'));
      await v1.close();

      final List<Migration> upgraded = <Migration>[
        ...kMigrations,
        const Migration(3, <String>[
          'ALTER TABLE conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
        ]),
      ];
      final AppDatabase v2 = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
        migrations: upgraded,
      );
      final List<Map<String, Object?>> version = await v2.db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, 3);
      final List<Map<String, Object?>> rows = await v2.db.query('conversations');
      expect(rows.single['title'], 'Keep me');
      expect(rows.single['pinned'], 0);
      expect((await SqliteConversationRepository(v2).loadMessages('c1')).single.text, 'still here');
      await v2.close();
    });
  });

  group('persistence and safety', () {
    test('data survives closing and reopening the database file', () async {
      final Directory dir = Directory.systemTemp.createTempSync('almus_db_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = p.join(dir.path, 'persist.db');

      final AppDatabase first = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
      final SqliteConversationRepository repo1 = SqliteConversationRepository(first);
      await repo1.createConversation(id: 'c1', title: 'Persistent chat');
      await repo1.addMessage(msg('m1', 'c1', 'Sannu'));
      await repo1.addMessage(msg('m2', 'c1', 'Barka', sender: MessageSender.assistant));
      await first.close();

      final AppDatabase second = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
      final SqliteConversationRepository repo2 = SqliteConversationRepository(second);
      final list = await repo2.listConversations();
      expect(list.single.title, 'Persistent chat');
      expect(list.single.messageCount, 2);
      final messages = await repo2.loadMessages('c1');
      expect(messages.map((m) => m.text), <String>['Sannu', 'Barka']);
      expect(messages.last.role, 'assistant');
      await second.close();
    });

    test('a closed database reports a safe StorageException', () async {
      final AppDatabase database = await _openMemory();
      final SqliteConversationRepository repo = SqliteConversationRepository(database);
      await repo.createConversation(id: 'c1');
      await database.close();

      try {
        await repo.addMessage(msg('m1', 'c1', 'secret message text'));
        fail('Expected a StorageException');
      } on StorageException catch (e) {
        expect(e.message, isNot(contains('secret')));
      }
    });

    test('opening an unusable path throws StorageException', () async {
      final Directory dir = Directory.systemTemp.createTempSync('almus_db_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(
        AppDatabase.open(factory: databaseFactoryFfi, path: dir.path),
        throwsA(isA<StorageException>()),
      );
    });

    test('the schema stores no credential columns', () async {
      final AppDatabase database = await _openMemory();
      final List<Map<String, Object?>> rows = await database.db
          .rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table'");
      final String schema = rows.map((Map<String, Object?> r) => '${r['sql']}'.toLowerCase()).join(' ');
      for (final String word in <String>['token', 'api_key', 'apikey', 'password', 'secret']) {
        expect(schema.contains(word), isFalse, reason: word);
      }
      await database.close();
    });
  });
}
