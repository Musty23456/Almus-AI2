import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_models.dart';

/// A file the user picked.
class PickedBackupFile {
  const PickedBackupFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// A file the user saved.
class SavedBackupFile {
  const SavedBackupFile(this.name, [this.location]);

  final String name;

  /// Where the system says it was saved (a path or content URI), if known.
  final String? location;
}

/// Opens and saves files through the Android system file picker (Storage
/// Access Framework). The user chooses the location, so a saved backup lives
/// outside the app's private storage. No storage permission is needed and no
/// network is used.
abstract class BackupFileGateway {
  /// Returns null when the user cancels.
  Future<PickedBackupFile?> pickFile();

  /// Returns null when the user cancels the save dialog.
  Future<SavedBackupFile?> saveFile({
    required String fileName,
    required Uint8List bytes,
  });

  /// Deletes the temporary copies the picker made in the app cache.
  Future<void> clearTemporaryFiles();
}

/// Real implementation backed by the `file_picker` plugin.
class FilePickerGateway implements BackupFileGateway {
  const FilePickerGateway();

  @override
  Future<PickedBackupFile?> pickFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final PlatformFile file = result.files.single;
    if (file.size > kMaxInputBytes) {
      throw const BackupException(
        'This file is too large to import.',
        BackupErrorCode.tooLarge,
      );
    }
    Uint8List? bytes = file.bytes;
    if (bytes == null) {
      final String? path = file.path;
      if (path == null) {
        throw const BackupException(
          'Android did not give ALMUS AI access to that file. Try choosing it again from Downloads or Files.',
        );
      }
      bytes = await File(path).readAsBytes();
    }
    return PickedBackupFile(file.name, bytes);
  }

  @override
  Future<SavedBackupFile?> saveFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final String? location = await FilePicker.platform.saveFile(
      dialogTitle: 'Save to a location outside ALMUS AI',
      fileName: fileName,
      bytes: bytes,
    );
    if (location == null) return null;
    return SavedBackupFile(fileName, location);
  }

  @override
  Future<void> clearTemporaryFiles() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } on Object {
      // Cleaning the cache is best effort.
    }
  }
}

/// What the Settings screen shows about earlier backups.
class BackupInfo {
  const BackupInfo({this.lastBackupAt, this.lastBackupLabel, this.lastRestoreAt});

  final DateTime? lastBackupAt;

  /// Short description, e.g. "Complete backup · encrypted · 12 chats".
  final String? lastBackupLabel;
  final DateTime? lastRestoreAt;
}

/// Remembers WHEN a backup was saved (never its contents or location). The
/// record only says that a save finished: the app cannot tell whether the file
/// still exists later.
abstract class BackupInfoStore {
  Future<BackupInfo> load();
  Future<void> saveBackup(DateTime at, String label);
  Future<void> saveRestore(DateTime at);
}

class PrefsBackupInfoStore implements BackupInfoStore {
  const PrefsBackupInfoStore();

  static const String _backupAt = 'backup_last_at';
  static const String _backupLabel = 'backup_last_label';
  static const String _restoreAt = 'backup_last_restore_at';

  @override
  Future<BackupInfo> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final int? backup = p.getInt(_backupAt);
    final int? restore = p.getInt(_restoreAt);
    return BackupInfo(
      lastBackupAt: backup == null ? null : DateTime.fromMillisecondsSinceEpoch(backup),
      lastBackupLabel: p.getString(_backupLabel),
      lastRestoreAt: restore == null ? null : DateTime.fromMillisecondsSinceEpoch(restore),
    );
  }

  @override
  Future<void> saveBackup(DateTime at, String label) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_backupAt, at.millisecondsSinceEpoch);
    await p.setString(_backupLabel, label);
  }

  @override
  Future<void> saveRestore(DateTime at) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_restoreAt, at.millisecondsSinceEpoch);
  }
}

class MemoryBackupInfoStore implements BackupInfoStore {
  BackupInfo info = const BackupInfo();

  @override
  Future<BackupInfo> load() async => info;

  @override
  Future<void> saveBackup(DateTime at, String label) async {
    info = BackupInfo(
      lastBackupAt: at,
      lastBackupLabel: label,
      lastRestoreAt: info.lastRestoreAt,
    );
  }

  @override
  Future<void> saveRestore(DateTime at) async {
    info = BackupInfo(
      lastBackupAt: info.lastBackupAt,
      lastBackupLabel: info.lastBackupLabel,
      lastRestoreAt: at,
    );
  }
}
