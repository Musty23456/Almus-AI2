import 'package:almus_ai/backup/backup_controller.dart';
import 'package:almus_ai/backup/backup_files.dart';
import 'package:almus_ai/backup/backup_models.dart';
import 'package:almus_ai/backup/backup_store.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/theme/app_theme.dart';
import 'package:almus_ai/widgets/backup_restore_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backup_fakes.dart';

/// Minimal in-memory store so widget tests need no database.
class _FakeStore implements BackupStore {
  BackupBundle data = BackupBundle(
    conversations: <BackupConversation>[makeConversation('a')],
  );

  @override
  Future<StoreCounts> counts() async =>
      StoreCounts(conversations: data.conversations.length, messages: data.messageCount);

  @override
  Future<BackupBundle> read({Set<String>? conversationIds, bool conversations = true, bool memories = true, bool settings = false}) async => data;

  @override
  Future<ImportSummary> plan(BackupBundle bundle, ImportOptions options) async => const ImportSummary();

  @override
  Future<ImportSummary> apply(BackupBundle bundle, ImportOptions options, {ImportProgressCallback? onProgress}) async => const ImportSummary();
}

void main() {
  testWidgets('Backup & Restore card lists every action and exports a file', (WidgetTester tester) async {
    final FakeBackupFileGateway files = FakeBackupFileGateway();
    final BackupController controller = BackupController(
      store: _FakeStore(),
      conversations: MemoryConversationRepository(),
      files: files,
      infoStore: MemoryBackupInfoStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: SingleChildScrollView(child: BackupRestoreCard(controller: controller))),
      ),
    );
    await tester.pump();

    for (final String key in <String>[
      'backup_export_all',
      'backup_export_selected',
      'backup_export_memory',
      'backup_create',
      'backup_import',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(find.text('None yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup_export_all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcript_format_json')));
    await tester.pumpAndSettle();

    expect(files.saved.single.name, endsWith('.json'));
    expect(find.byKey(const Key('backup_success')), findsOneWidget);
  });

  testWidgets('the password dialog rejects mismatched passwords', (WidgetTester tester) async {
    final FakeBackupFileGateway files = FakeBackupFileGateway();
    final BackupController controller = BackupController(
      store: _FakeStore(),
      conversations: MemoryConversationRepository(),
      files: files,
      infoStore: MemoryBackupInfoStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: SingleChildScrollView(child: BackupRestoreCard(controller: controller))),
      ),
    );
    await tester.tap(find.byKey(const Key('backup_create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('backup_password_field')), 'password-one');
    await tester.enterText(find.byKey(const Key('backup_password_confirm_field')), 'password-two');
    await tester.tap(find.byKey(const Key('backup_dialog_create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup_dialog_error')), findsOneWidget);
    expect(files.saved, isEmpty);
  });
}
