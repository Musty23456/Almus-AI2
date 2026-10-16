import 'dart:typed_data';

import 'package:almus_ai/backup/backup_files.dart';
import 'package:almus_ai/backup/backup_models.dart';

/// Records saved files and returns a prepared file when asked to pick one.
class FakeBackupFileGateway implements BackupFileGateway {
  FakeBackupFileGateway({this.toPick});

  PickedBackupFile? toPick;
  bool cancelSave = false;
  final List<SavedFile> saved = <SavedFile>[];
  int cleaned = 0;

  @override
  Future<PickedBackupFile?> pickFile() async => toPick;

  @override
  Future<SavedBackupFile?> saveFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (cancelSave) return null;
    saved.add(SavedFile(fileName, bytes));
    return SavedBackupFile(fileName, '/fake/$fileName');
  }

  @override
  Future<void> clearTemporaryFiles() async => cleaned++;
}

class SavedFile {
  SavedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

DateTime t(int minute) => DateTime.utc(2026, 1, 1, 10, minute);

BackupConversation makeConversation(
  String id, {
  String title = 'Chat',
  int messages = 2,
  int minute = 0,
  String text = 'Hello',
}) {
  return BackupConversation(
    id: id,
    title: title,
    createdAt: t(minute),
    updatedAt: t(minute + messages),
    messages: <BackupMessage>[
      for (int i = 0; i < messages; i++)
        BackupMessage(
          id: '$id-m$i',
          conversationId: id,
          role: i.isEven ? 'user' : 'assistant',
          content: '$text $i',
          createdAt: t(minute + i),
        ),
    ],
  );
}

BackupMemory makeMemory(String id, {String text = 'Likes tea', String category = 'preference'}) {
  return BackupMemory(
    id: id,
    category: category,
    text: text,
    createdAt: t(1),
    updatedAt: t(2),
  );
}
