import 'package:almus_ai/backup/backup_models.dart';
import 'package:almus_ai/backup/backup_store.dart';
import 'package:almus_ai/backup/sqlite_backup_store.dart';
import 'package:almus_ai/data/app_database.dart';
import 'package:almus_ai/data/sqlite_conversation_repository.dart';
import 'package:almus_ai/data/sqlite_memory_repository.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_fakes.dart';

Future<AppDatabase> openMemory() =>
    AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);

Future<StoreCounts> counts(AppDatabase d) => SqliteBackupStore(d).counts();

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteBackupStore store;

  setUp(() async {
    db = await openMemory();
    store = SqliteBackupStore(db);
  });
  tearDown(() async => db.close());

  Future<void> seed() async {
    await store.apply(
      BackupBundle(
        conversations: <BackupConversation>[makeConversation('old1', text: 'old'), makeConversation('old2', messages: 0)],
        memories: <BackupMemory>[makeMemory('om1', text: 'Old memory')],
        settings: const BackupSettings(memoryEnabled: true),
      ),
      const ImportOptions(),
    );
  }

  group('read', () {
    test('exports stored data with ids, order and timestamps', () async {
      await seed();
      final BackupBundle b = await store.read(settings: true);
      expect(b.conversations.map((BackupConversation c) => c.id), <String>['old1', 'old2']);
      expect(b.conversations.first.messages.map((BackupMessage m) => m.id), <String>['old1-m0', 'old1-m1']);
      expect(b.conversations.first.createdAt, t(0));
      expect(b.memories.single.id, 'om1');
      expect(b.settings!.memoryEnabled, true);
    });

    test('selected conversations only', () async {
      await seed();
      final BackupBundle b = await store.read(conversationIds: <String>{'old2'}, memories: false);
      expect(b.conversations.single.id, 'old2');
      expect(b.memories, isEmpty);
    });

    test('empty database exports an empty bundle', () async {
      final BackupBundle b = await store.read(settings: true);
      expect(b.conversations, isEmpty);
      expect(b.memories, isEmpty);
    });
  });

  group('merge', () {
    test('adds new data, skips duplicates, never overwrites', () async {
      await seed();
      final BackupBundle incoming = BackupBundle(
        conversations: <BackupConversation>[
          makeConversation('old1', title: 'DIFFERENT TITLE', text: 'changed'),
          makeConversation('new1'),
        ],
        memories: <BackupMemory>[
          makeMemory('om1', text: 'changed text'),
          makeMemory('om-other-id', text: '  old   MEMORY '),
          makeMemory('nm1', text: 'Fresh'),
        ],
      );
      final ImportSummary plan = await store.plan(incoming, const ImportOptions());
      expect(plan.newConversations, 1);
      expect(plan.duplicateConversations, 1);
      expect(plan.newMemories, 1);
      expect(plan.duplicateMemories, 2);
      // A dry run changes nothing.
      expect(await counts(db), const StoreCounts(conversations: 2, messages: 2, memories: 1));

      final ImportSummary result = await store.apply(incoming, const ImportOptions());
      expect(result.newConversations, 1);
      final BackupBundle after = await store.read();
      expect(after.conversations.length, 3);
      expect(after.conversations.firstWhere((BackupConversation c) => c.id == 'old1').title, 'Chat');
      expect(after.conversations.firstWhere((BackupConversation c) => c.id == 'old1').messages.first.content, 'old 0');
      expect(after.memories.length, 2);
    });

    test('an existing conversation receives only the messages it lacks', () async {
      await seed();
      final BackupConversation longer = makeConversation('old1', messages: 4, text: 'old');
      final ImportSummary s = await store.apply(BackupBundle(conversations: <BackupConversation>[longer]), const ImportOptions());
      expect(s.mergedConversations, 1);
      expect(s.newMessages, 2);
      expect(s.duplicateMessages, 2);
      final BackupConversation c = (await store.read()).conversations.firstWhere((BackupConversation c) => c.id == 'old1');
      expect(c.messages.map((BackupMessage m) => m.id), <String>['old1-m0', 'old1-m1', 'old1-m2', 'old1-m3']);
      expect(c.updatedAt, t(4));
    });

    test('a message id owned by another conversation is skipped, not overwritten', () async {
      await seed();
      final BackupConversation clash = BackupConversation(
        id: 'other',
        title: 't',
        createdAt: t(0),
        updatedAt: t(1),
        messages: <BackupMessage>[
          BackupMessage(id: 'old1-m0', conversationId: 'other', role: 'user', content: 'x', createdAt: t(0)),
        ],
      );
      final ImportSummary s = await store.apply(BackupBundle(conversations: <BackupConversation>[clash]), const ImportOptions());
      expect(s.conflictingMessages, 1);
      expect(s.newConversations, 1);
      expect((await store.read()).conversations.firstWhere((BackupConversation c) => c.id == 'old1').messages.first.content, 'old 0');
    });

    test('importing the same file repeatedly changes nothing after the first time', () async {
      final BackupBundle file = BackupBundle(
        conversations: <BackupConversation>[makeConversation('a'), makeConversation('b')],
        memories: <BackupMemory>[makeMemory('m')],
      );
      await store.apply(file, const ImportOptions());
      final StoreCounts once = await counts(db);
      for (int i = 0; i < 3; i++) {
        final ImportSummary s = await store.apply(file, const ImportOptions());
        expect(s.totalChanges, 0);
      }
      expect(await counts(db), once);
    });

    test('merge keeps the current master memory switch', () async {
      await seed();
      await store.apply(BackupBundle(settings: const BackupSettings(memoryEnabled: false)), const ImportOptions());
      expect((await store.read(settings: true)).settings!.memoryEnabled, true);
    });

    test('large merge (20,000 messages) is stored completely', () async {
      final BackupBundle big = BackupBundle(
        conversations: <BackupConversation>[for (int i = 0; i < 100; i++) makeConversation('c$i', messages: 200)],
      );
      final List<ImportProgress> progress = <ImportProgress>[];
      await store.apply(big, const ImportOptions(), onProgress: progress.add);
      expect((await counts(db)).messages, 20000);
      expect(progress.last.done, progress.last.total);
    });
  });

  group('replace', () {
    test('replaces selected data and reports what was removed', () async {
      await seed();
      final BackupBundle incoming = BackupBundle(
        conversations: <BackupConversation>[makeConversation('n1')],
        memories: <BackupMemory>[makeMemory('nm')],
        settings: const BackupSettings(memoryEnabled: false, conversationMemoryOff: <String>['n1']),
      );
      final ImportSummary plan = await store.plan(incoming, const ImportOptions(mode: ImportMode.replace));
      expect(plan.removed, const StoreCounts(conversations: 2, messages: 2, memories: 1));
      final ImportSummary s = await store.apply(incoming, const ImportOptions(mode: ImportMode.replace));
      expect(s.removed.conversations, 2);
      final BackupBundle after = await store.read(settings: true);
      expect(after.conversations.map((BackupConversation c) => c.id), <String>['n1']);
      expect(after.memories.single.id, 'nm');
      expect(after.settings!.memoryEnabled, false);
      expect(after.settings!.conversationMemoryOff, <String>['n1']);
    });

    test('unselected sections are left alone', () async {
      await seed();
      await store.apply(
        BackupBundle(conversations: <BackupConversation>[makeConversation('n1')]),
        const ImportOptions(mode: ImportMode.replace, memories: false, settings: false),
      );
      final BackupBundle after = await store.read();
      expect(after.conversations.single.id, 'n1');
      expect(after.memories.single.id, 'om1');
    });

    test('replace with an empty backup removes the chosen data (UI must confirm first)', () async {
      await seed();
      await store.apply(const BackupBundle(), const ImportOptions(mode: ImportMode.replace));
      expect(await counts(db), const StoreCounts());
    });

    test('does not touch unrelated tables', () async {
      await seed();
      await db.db.insert('memory_prefs', <String, Object?>{'name': 'other_pref', 'value': 'keep'});
      await store.apply(BackupBundle(conversations: <BackupConversation>[makeConversation('n1')]), const ImportOptions(mode: ImportMode.replace));
      final List<Map<String, Object?>> rows = await db.db.query('memory_prefs', where: "name = 'other_pref'");
      expect(rows.length, 1);
    });
  });

  group('failure and rollback', () {
    test('a failing insert rolls back everything, including a replace delete', () async {
      await seed();
      await db.db.execute(
        "CREATE TRIGGER boom BEFORE INSERT ON messages WHEN NEW.content = 'BOOM' BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      final BackupConversation poisoned = BackupConversation(
        id: 'p',
        title: 'p',
        createdAt: t(0),
        updatedAt: t(1),
        messages: <BackupMessage>[
          BackupMessage(id: 'p0', conversationId: 'p', role: 'user', content: 'fine', createdAt: t(0)),
          BackupMessage(id: 'p1', conversationId: 'p', role: 'user', content: 'BOOM', createdAt: t(1)),
        ],
      );
      final StoreCounts before = await counts(db);
      await expectLater(
        store.apply(
          BackupBundle(conversations: <BackupConversation>[makeConversation('ok'), poisoned], memories: <BackupMemory>[makeMemory('zz', text: 'new')]),
          const ImportOptions(mode: ImportMode.replace),
        ),
        throwsA(isA<BackupException>().having((BackupException e) => e.code, 'code', BackupErrorCode.storage)),
      );
      expect(await counts(db), before);
      final BackupBundle after = await store.read();
      expect(after.conversations.map((BackupConversation c) => c.id), <String>['old1', 'old2']);
      expect(after.memories.single.id, 'om1');
    });

    test('a failed merge leaves the data unchanged too', () async {
      await seed();
      await db.db.execute(
        "CREATE TRIGGER boom BEFORE INSERT ON memories WHEN NEW.text = 'BOOM' BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      final StoreCounts before = await counts(db);
      await expectLater(
        store.apply(
          BackupBundle(conversations: <BackupConversation>[makeConversation('n1')], memories: <BackupMemory>[makeMemory('bad', text: 'BOOM')]),
          const ImportOptions(),
        ),
        throwsA(isA<BackupException>()),
      );
      expect(await counts(db), before);
    });

    test('the error message never contains chat text', () async {
      await seed();
      await db.db.execute("CREATE TRIGGER boom BEFORE INSERT ON messages WHEN NEW.content = 'SECRET-TEXT' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final BackupConversation c = BackupConversation(
        id: 'p', title: 'p', createdAt: t(0), updatedAt: t(1),
        messages: <BackupMessage>[BackupMessage(id: 'p0', conversationId: 'p', role: 'user', content: 'SECRET-TEXT', createdAt: t(0))],
      );
      try {
        await store.apply(BackupBundle(conversations: <BackupConversation>[c]), const ImportOptions());
        fail('should throw');
      } on BackupException catch (e) {
        expect(e.message.contains('SECRET'), isFalse);
      }
    });
  });

  test('Hausa and Unicode text survive storage unchanged', () async {
    const String text = 'Ɓarna ɗan ƙasa ƴar uwa — 你好 🌍';
    await store.apply(BackupBundle(conversations: <BackupConversation>[makeConversation('u', text: text)]), const ImportOptions());
    final BackupBundle b = await store.read();
    expect(b.conversations.single.messages.first.content, '$text 0');
  });

  test('exported data from the real repositories imports into a fresh database', () async {
    final SqliteConversationRepository repo = SqliteConversationRepository(db);
    final SqliteMemoryRepository mem = SqliteMemoryRepository(db);
    final Conversation conv = await repo.createConversation(title: 'Real chat');
    await repo.addMessage(ChatMessage(
      id: 'm1',
      text: 'Sannu ƙwarai',
      sender: MessageSender.user,
      timestamp: DateTime.now(),
      conversationId: conv.id,
    ));
    final BackupBundle bundle = await store.read(settings: true);

    final AppDatabase fresh = await openMemory();
    final SqliteBackupStore freshStore = SqliteBackupStore(fresh);
    await freshStore.apply(bundle, const ImportOptions(mode: ImportMode.replace));
    final BackupBundle copy = await freshStore.read();
    expect(copy.conversations.single.title, 'Real chat');
    expect(copy.conversations.single.messages.single.content, 'Sannu ƙwarai');
    expect(await mem.list(), isEmpty);
    await fresh.close();
  });
}
