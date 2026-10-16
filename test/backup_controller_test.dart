import 'dart:convert';
import 'dart:typed_data';

import 'package:almus_ai/backup/backup_controller.dart';
import 'package:almus_ai/backup/backup_crypto.dart';
import 'package:almus_ai/backup/backup_files.dart';
import 'package:almus_ai/backup/backup_models.dart';
import 'package:almus_ai/backup/backup_store.dart';
import 'package:almus_ai/backup/sqlite_backup_store.dart';
import 'package:almus_ai/backup/transcript_formats.dart';
import 'package:almus_ai/data/app_database.dart';
import 'package:almus_ai/data/sqlite_conversation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_fakes.dart';

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteBackupStore store;
  late FakeBackupFileGateway files;
  late MemoryBackupInfoStore info;
  late BackupController controller;
  int restored = 0;

  BackupController build(AppDatabase database, SqliteBackupStore s, FakeBackupFileGateway f) {
    return BackupController(
      store: s,
      conversations: SqliteConversationRepository(database),
      files: f,
      infoStore: info,
      crypto: BackupCrypto.forTesting(iterations: 1000),
      onDataRestored: () async => restored++,
    );
  }

  setUp(() async {
    db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = SqliteBackupStore(db);
    files = FakeBackupFileGateway();
    info = MemoryBackupInfoStore();
    restored = 0;
    controller = build(db, store, files);
    await store.apply(
      BackupBundle(
        conversations: <BackupConversation>[makeConversation('a', text: 'Ɓarna'), makeConversation('b')],
        memories: <BackupMemory>[makeMemory('m1')],
      ),
      const ImportOptions(),
    );
  });
  tearDown(() async => db.close());

  test('export all conversations as JSON, TXT and Markdown', () async {
    for (final TranscriptFormat f in TranscriptFormat.values) {
      await controller.exportConversations(format: f);
      expect(controller.phase, BackupPhase.success, reason: f.name);
    }
    expect(files.saved.map((SavedFile s) => s.name.split('.').last), <String>['json', 'md', 'txt']);
    expect(utf8.decode(files.saved.first.bytes), contains('Ɓarna'));
  });

  test('export selected conversations only', () async {
    await controller.exportConversations(ids: <String>{'b'}, format: TranscriptFormat.json);
    final String text = utf8.decode(files.saved.single.bytes);
    expect(text, contains('"id": "b"'));
    expect(text, isNot(contains('"id": "a"')));
  });

  test('cancelling the save dialog saves and records nothing', () async {
    files.cancelSave = true;
    await controller.createCompleteBackup();
    expect(files.saved, isEmpty);
    expect((await info.load()).lastBackupAt, isNull);
    expect(controller.messageIsError, isFalse);
  });

  test('export of nothing says so', () async {
    await store.apply(const BackupBundle(), const ImportOptions(mode: ImportMode.replace));
    await controller.exportConversations(format: TranscriptFormat.txt);
    expect(controller.phase, BackupPhase.failure);
    expect(files.saved, isEmpty);
  });

  test('memory export', () async {
    await controller.exportMemories(MemoryExportFormat.json);
    expect(utf8.decode(files.saved.single.bytes), contains('Likes tea'));
  });

  test('complete backup is a ZIP, records last-backup info, restores into a fresh database', () async {
    await controller.createCompleteBackup();
    expect(controller.phase, BackupPhase.success);
    expect(files.saved.single.name, endsWith('-unencrypted.zip'));
    expect(controller.info.lastBackupAt, isNotNull);

    // Simulate "reinstall": new empty database, file picked from outside storage.
    final AppDatabase fresh = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final SqliteBackupStore freshStore = SqliteBackupStore(fresh);
    final FakeBackupFileGateway pick = FakeBackupFileGateway(
      toPick: PickedBackupFile(files.saved.single.name, files.saved.single.bytes),
    );
    final BackupController c2 = build(fresh, freshStore, pick);
    expect(await c2.pickBackupFile(), PickResult.ready);
    await c2.runImport(const ImportOptions());
    expect(c2.phase, BackupPhase.success);
    expect(restored, 1);
    expect(await freshStore.counts(), const StoreCounts(conversations: 2, messages: 4, memories: 1));
    expect(pick.cleaned, greaterThan(0));
    await fresh.close();
  });

  test('encrypted backup: password required, wrong password retried, right password works', () async {
    await controller.createCompleteBackup(password: 'secret-pass');
    expect(files.saved.single.name, endsWith('-ENCRYPTED.almusenc'));
    final PickedBackupFile picked = PickedBackupFile('x.almusenc', files.saved.single.bytes);

    final BackupController c2 = build(db, store, FakeBackupFileGateway(toPick: picked));
    expect(await c2.pickBackupFile(), PickResult.needsPassword);
    expect(await c2.unlockPending('wrong-pass'), isNotNull);
    expect(c2.pending, isNull);
    expect(await c2.unlockPending('secret-pass'), isNull);
    expect(c2.pending!.parsed.encrypted, isTrue);
  });

  test('weak password is refused before anything is saved', () async {
    await controller.createCompleteBackup(password: 'short');
    expect(controller.phase, BackupPhase.failure);
    expect(files.saved, isEmpty);
  });

  test('invalid files give a failure message and change nothing', () async {
    final FakeBackupFileGateway pick = FakeBackupFileGateway(
      toPick: PickedBackupFile('bad.json', Uint8List.fromList(utf8.encode('{not json'))),
    );
    final BackupController c2 = build(db, store, pick);
    expect(await c2.pickBackupFile(), PickResult.failed);
    expect(c2.messageIsError, isTrue);
    expect(await store.counts(), const StoreCounts(conversations: 2, messages: 4, memories: 1));
  });

  test('replace with safety backup saves the current data first; cancelled safety backup aborts', () async {
    final BackupBundle incoming = BackupBundle(conversations: <BackupConversation>[makeConversation('z')]);
    final String json = conversationsToJson(incoming.conversations, appVersion: '1', exportedAt: DateTime.utc(2026));
    final FakeBackupFileGateway pick = FakeBackupFileGateway(
      toPick: PickedBackupFile('in.json', Uint8List.fromList(utf8.encode(json))),
    );
    final BackupController c2 = build(db, store, pick);
    await c2.pickBackupFile();

    pick.cancelSave = true;
    await c2.runImport(const ImportOptions(mode: ImportMode.replace), safetyBackup: true);
    expect(await store.counts(), const StoreCounts(conversations: 2, messages: 4, memories: 1));
    expect(c2.messageIsError, isTrue);

    pick.cancelSave = false;
    await c2.runImport(const ImportOptions(mode: ImportMode.replace, memories: false), safetyBackup: true);
    expect(pick.saved.single.name, contains('safety-backup'));
    expect((await store.read()).conversations.single.id, 'z');
    expect((await store.read()).memories.single.id, 'm1');
  });

  test('restore can be blocked while the assistant is busy', () async {
    final String json = conversationsToJson(<BackupConversation>[makeConversation('z')], appVersion: '1', exportedAt: DateTime.utc(2026));
    final BackupController c2 = BackupController(
      store: store,
      conversations: SqliteConversationRepository(db),
      files: FakeBackupFileGateway(toPick: PickedBackupFile('in.json', Uint8List.fromList(utf8.encode(json)))),
      infoStore: info,
      restoreBlockedReason: () => 'busy',
    );
    await c2.pickBackupFile();
    await c2.runImport(const ImportOptions());
    expect(c2.message, 'busy');
    expect((await store.counts()).conversations, 2);
  });

  test('describeImport mentions removed and skipped counts', () {
    final String text = describeImport(
      const ImportSummary(newConversations: 1, duplicateMessages: 2, removed: StoreCounts(conversations: 3)),
      const ImportOptions(mode: ImportMode.replace),
    );
    expect(text, contains('3 conversations'));
    expect(text, contains('Skipped'));
  });
}
