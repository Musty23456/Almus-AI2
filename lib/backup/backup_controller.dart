import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/conversation_repository.dart';
import '../models/conversation.dart';
import '../utils/app_info.dart';
import 'backup_codec.dart';
import 'backup_crypto.dart';
import 'backup_files.dart';
import 'backup_models.dart';
import 'backup_store.dart';
import 'import_adapters.dart';
import 'transcript_formats.dart';

enum BackupPhase { idle, working, success, failure }

/// Result of choosing a file to import.
enum PickResult { cancelled, needsPassword, ready, failed }

/// A file that was read and validated but not stored yet.
class PendingImport {
  const PendingImport(this.fileName, this.parsed);

  final String fileName;
  final ParsedImport parsed;

  BackupBundle get bundle => parsed.bundle;
}

class _Result {
  const _Result(this.message, {required this.ok});

  final String message;
  final bool ok;
}

/// Drives the Backup & Restore section of Settings. It holds no UI code.
class BackupController extends ChangeNotifier {
  BackupController({
    required this.store,
    required this.conversations,
    required this.files,
    required this.infoStore,
    BackupCrypto? crypto,
    ImportService? importer,
    this.codec = const BackupCodec(),
    DateTime Function()? clock,
    this.onDataRestored,
    this.restoreBlockedReason,
  })  : _crypto = crypto ?? BackupCrypto(),
        _clock = clock ?? DateTime.now {
    _importer = importer ?? ImportService(crypto: _crypto, clock: _clock);
  }

  final BackupStore store;
  final ConversationRepository conversations;
  final BackupFileGateway files;
  final BackupInfoStore infoStore;
  final BackupCodec codec;
  final BackupCrypto _crypto;
  final DateTime Function() _clock;
  late final ImportService _importer;

  /// Called after a restore so the rest of the app can reload its lists.
  final Future<void> Function()? onDataRestored;

  /// Returns a reason when a restore must not start now (for example while
  /// the assistant is writing a reply), or null when it is fine.
  final String? Function()? restoreBlockedReason;

  BackupPhase _phase = BackupPhase.idle;
  String _stage = '';
  double? _fraction;
  String? _message;
  bool _messageIsError = false;
  BackupInfo _info = const BackupInfo();
  PendingImport? _pending;
  Uint8List? _lockedBytes;
  String _lockedName = '';
  bool _disposed = false;

  BackupPhase get phase => _phase;
  bool get isBusy => _phase == BackupPhase.working;
  String get stage => _stage;

  /// 0..1, or null when the progress is not measurable.
  double? get fraction => _fraction;
  String? get message => _message;
  bool get messageIsError => _messageIsError;
  BackupInfo get info => _info;
  PendingImport? get pending => _pending;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _begin(String stage) {
    _phase = BackupPhase.working;
    _stage = stage;
    _fraction = null;
    _message = null;
    _notify();
  }

  void _setStage(String stage, [double? fraction]) {
    _stage = stage;
    _fraction = fraction;
    _notify();
  }

  void _finish(String message, {required bool ok}) {
    _phase = ok ? BackupPhase.success : BackupPhase.failure;
    _message = message;
    _messageIsError = !ok;
    _stage = '';
    _fraction = null;
    _notify();
  }

  void _idle() {
    _phase = BackupPhase.idle;
    _stage = '';
    _fraction = null;
    _notify();
  }

  void dismissMessage() {
    if (isBusy) return;
    _message = null;
    _phase = BackupPhase.idle;
    _notify();
  }

  Future<void> loadInfo() async {
    try {
      _info = await infoStore.load();
      _notify();
    } on Object {
      // The "last backup" line is optional.
    }
  }

  Future<List<Conversation>> listConversations() =>
      conversations.listConversations(limit: 1 << 30);

  Future<void> _run(String stage, Future<_Result?> Function() action) async {
    if (isBusy) return;
    _begin(stage);
    try {
      final _Result? result = await action();
      if (result == null) {
        _message = 'Cancelled. Nothing was saved or changed.';
        _messageIsError = false;
        _idle();
      } else {
        _finish(result.message, ok: result.ok);
      }
    } on BackupException catch (e) {
      _finish(e.message, ok: false);
    } on Object {
      _finish('Something went wrong. Nothing was changed.', ok: false);
    }
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static String _plural(int n, String one, [String? many]) =>
      '$n ${n == 1 ? one : (many ?? '${one}s')}';

  static const String _keepNote =
      'Keep it outside ALMUS AI (Downloads, a memory card, or a cloud app you choose yourself). Files in the app\'s private storage are deleted when the app is uninstalled.';

  // ----------------------------------------------------- conversation export

  /// Exports [ids] (null = every conversation) in [format].
  Future<void> exportConversations({
    Set<String>? ids,
    required TranscriptFormat format,
  }) {
    return _run('Reading your conversations', () async {
      final BackupBundle bundle = await store.read(
        conversationIds: ids,
        conversations: true,
        memories: false,
      );
      if (bundle.conversations.isEmpty) {
        return const _Result('There are no conversations to export.', ok: false);
      }
      final DateTime now = _clock();
      _setStage('Building the ${format.extension.toUpperCase()} file');
      final String text = switch (format) {
        TranscriptFormat.json => conversationsToJson(
            bundle.conversations,
            appVersion: AppInfo.version,
            exportedAt: now,
          ),
        TranscriptFormat.markdown => conversationsToMarkdown(
            bundle.conversations,
            appVersion: AppInfo.version,
            exportedAt: now,
          ),
        TranscriptFormat.txt => conversationsToTxt(
            bundle.conversations,
            appVersion: AppInfo.version,
            exportedAt: now,
          ),
      };
      if (format == TranscriptFormat.json) {
        // Read the file back before saving it.
        final BackupBundle check =
            BackupBundle.fromExportJson(asJsonMap(jsonDecode(text), 'export'));
        if (check.conversations.length != bundle.conversations.length ||
            check.messageCount != bundle.messageCount) {
          throw const BackupException(
            'The export could not be verified, so it was not saved.',
            BackupErrorCode.corrupted,
          );
        }
      }
      final String scope = ids == null
          ? 'all-conversations'
          : (ids.length == 1 ? 'conversation' : 'selected-conversations');
      final String name = 'almus-$scope-${_stamp(now)}.${format.extension}';
      _setStage('Waiting for you to choose where to save');
      final SavedBackupFile? saved =
          await files.saveFile(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)));
      if (saved == null) return null;
      return _Result(
        'Saved ${_plural(bundle.conversations.length, 'conversation')} '
        '(${_plural(bundle.messageCount, 'message')}) to ${saved.name}. '
        'This file is NOT encrypted.',
        ok: true,
      );
    });
  }

  // ----------------------------------------------------------- memory export

  Future<void> exportMemories(MemoryExportFormat format) {
    return _run('Reading your memories', () async {
      final BackupBundle bundle = await store.read(conversations: false, memories: true);
      if (bundle.memories.isEmpty) {
        return const _Result('There are no personal memories to export.', ok: false);
      }
      final DateTime now = _clock();
      final String text = format == MemoryExportFormat.json
          ? memoriesToJson(bundle.memories, appVersion: AppInfo.version, exportedAt: now)
          : memoriesToMarkdown(bundle.memories, appVersion: AppInfo.version, exportedAt: now);
      final String name = 'almus-memory-${_stamp(now)}.${format.extension}';
      _setStage('Waiting for you to choose where to save');
      final SavedBackupFile? saved =
          await files.saveFile(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)));
      if (saved == null) return null;
      return _Result(
        'Saved ${_plural(bundle.memories.length, 'memory', 'memories')} to ${saved.name}. '
        'This file is NOT encrypted.',
        ok: true,
      );
    });
  }

  // --------------------------------------------------------- complete backup

  /// Creates a complete backup. With a [password] the archive is encrypted.
  Future<void> createCompleteBackup({String? password}) {
    return _run('Reading your data', () async {
      final String? weak = password == null ? null : BackupCrypto.passwordProblem(password);
      if (weak != null) {
        throw BackupException(weak, BackupErrorCode.weakPassword);
      }
      final BackupBundle bundle = await store.read(settings: true);
      final DateTime now = _clock();
      _setStage('Building the backup archive');
      final Uint8List zip = codec.encodeZip(
        bundle,
        appName: AppInfo.name,
        appVersion: AppInfo.version,
        appBuild: AppInfo.build,
        now: now,
      );
      _setStage('Checking the archive');
      final BackupBundle check = codec.decodeZip(zip);
      if (check.conversations.length != bundle.conversations.length ||
          check.messageCount != bundle.messageCount ||
          check.memories.length != bundle.memories.length) {
        throw const BackupException(
          'The backup could not be verified, so it was not saved.',
          BackupErrorCode.corrupted,
        );
      }

      Uint8List out = zip;
      String name = 'almus-backup-${_stamp(now)}-unencrypted.zip';
      if (password != null) {
        _setStage('Encrypting (this can take a few seconds)');
        out = await _crypto.encrypt(zip, password, appVersion: AppInfo.version, now: now);
        _setStage('Checking the encrypted file');
        final Uint8List back = await _crypto.decrypt(out, password);
        if (sha256Hex(back) != sha256Hex(zip)) {
          throw const BackupException(
            'The encrypted backup could not be verified, so it was not saved.',
            BackupErrorCode.corrupted,
          );
        }
        name = 'almus-backup-${_stamp(now)}-ENCRYPTED.almusenc';
      }

      _setStage('Waiting for you to choose where to save');
      final SavedBackupFile? saved = await files.saveFile(fileName: name, bytes: out);
      if (saved == null) return null;

      final String label =
          'Complete backup · ${password == null ? 'not encrypted' : 'encrypted'} · '
          '${_plural(bundle.conversations.length, 'chat')}, '
          '${_plural(bundle.memories.length, 'memory', 'memories')}';
      try {
        await infoStore.saveBackup(now, label);
        _info = await infoStore.load();
      } on Object {
        // The record is a convenience only.
      }
      return _Result(
        'Backup saved as ${saved.name}: ${_plural(bundle.conversations.length, 'conversation')}, '
        '${_plural(bundle.messageCount, 'message')}, '
        '${_plural(bundle.memories.length, 'memory', 'memories')}. '
        '${password == null ? 'It is NOT encrypted. ' : ''}$_keepNote',
        ok: true,
      );
    });
  }

  // ------------------------------------------------------------------ import

  /// Opens the system file picker and reads the chosen file.
  Future<PickResult> pickBackupFile() async {
    if (isBusy) return PickResult.failed;
    _pending = null;
    _lockedBytes = null;
    _begin('Choosing a file');
    try {
      final PickedBackupFile? picked = await files.pickFile();
      if (picked == null) {
        _message = null;
        _idle();
        return PickResult.cancelled;
      }
      _setStage('Checking the file');
      if (_importer.isEncrypted(picked.bytes)) {
        _lockedBytes = picked.bytes;
        _lockedName = picked.name;
        _idle();
        return PickResult.needsPassword;
      }
      final ParsedImport parsed =
          await _importer.inspect(picked.bytes, fileName: picked.name);
      _pending = PendingImport(picked.name, parsed);
      _idle();
      return PickResult.ready;
    } on BackupException catch (e) {
      _finish(e.message, ok: false);
      return PickResult.failed;
    } on Object {
      _finish('That file could not be read.', ok: false);
      return PickResult.failed;
    } finally {
      unawaited(files.clearTemporaryFiles());
    }
  }

  /// Decrypts the file waiting for a password. Returns null on success, or a
  /// message to show next to the password field (the user may try again).
  Future<String?> unlockPending(String password) async {
    final Uint8List? bytes = _lockedBytes;
    if (bytes == null) return 'No encrypted file is waiting for a password.';
    if (isBusy) return 'Please wait for the current task to finish.';
    _begin('Decrypting (this can take a few seconds)');
    try {
      final ParsedImport parsed =
          await _importer.inspect(bytes, fileName: _lockedName, password: password);
      _pending = PendingImport(_lockedName, parsed);
      _lockedBytes = null;
      _idle();
      return null;
    } on BackupException catch (e) {
      if (e.code != BackupErrorCode.wrongPassword) _lockedBytes = null;
      _idle();
      return e.message;
    } on Object {
      _lockedBytes = null;
      _idle();
      return 'The backup could not be decrypted.';
    }
  }

  /// Dry run for the preview screen.
  Future<ImportSummary> previewFor(ImportOptions options) {
    final PendingImport? p = _pending;
    if (p == null) {
      throw const BackupException('No file is ready to import.');
    }
    return store.plan(p.bundle, options);
  }

  Future<StoreCounts> currentCounts() => store.counts();

  void discardPending() {
    _pending = null;
    _lockedBytes = null;
    _notify();
  }

  /// Stores the pending file. Everything happens in one database transaction;
  /// a failure leaves the existing data untouched. With [safetyBackup] (replace
  /// only) the current data is first saved to a file you choose.
  Future<void> runImport(ImportOptions options, {bool safetyBackup = false}) async {
    final PendingImport? p = _pending;
    if (p == null || isBusy) return;
    final String? blocked = restoreBlockedReason?.call();
    if (blocked != null) {
      _finish(blocked, ok: false);
      return;
    }
    await _run('Starting the import', () async {
      final DateTime now = _clock();
      if (safetyBackup && options.mode == ImportMode.replace) {
        _setStage('Saving a safety backup of your current data');
        final BackupBundle current = await store.read(settings: true);
        final Uint8List zip = codec.encodeZip(
          current,
          appName: AppInfo.name,
          appVersion: AppInfo.version,
          appBuild: AppInfo.build,
          now: now,
        );
        final SavedBackupFile? saved = await files.saveFile(
          fileName: 'almus-safety-backup-${_stamp(now)}-unencrypted.zip',
          bytes: zip,
        );
        if (saved == null) {
          return const _Result(
            'Replace cancelled: no safety backup was saved, so nothing was changed.',
            ok: false,
          );
        }
      }
      final ImportSummary summary = await store.apply(
        p.bundle,
        options,
        onProgress: (ImportProgress progress) =>
            _setStage(progress.stage, progress.fraction),
      );
      _pending = null;
      try {
        await infoStore.saveRestore(now);
        _info = await infoStore.load();
      } on Object {
        // Optional record.
      }
      try {
        await onDataRestored?.call();
      } on Object {
        // The data is stored; lists refresh the next time they load.
      }
      return _Result(describeImport(summary, options), ok: true);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Plain-language result of an import.
String describeImport(ImportSummary s, ImportOptions options) {
  String n(int count, String one, [String? many]) =>
      '$count ${count == 1 ? one : (many ?? '${one}s')}';
  final StringBuffer b = StringBuffer(
    options.mode == ImportMode.replace ? 'Restore finished (replace). ' : 'Import finished (merge). ',
  );
  if (options.mode == ImportMode.replace) {
    b.write(
      'Removed before restoring: ${n(s.removed.conversations, 'conversation')}, '
      '${n(s.removed.messages, 'message')}, ${n(s.removed.memories, 'memory', 'memories')}. ',
    );
  }
  b.write(
    'Added: ${n(s.newConversations, 'conversation')}, ${n(s.newMessages, 'message')}, '
    '${n(s.newMemories, 'memory', 'memories')}.',
  );
  if (s.mergedConversations > 0) {
    b.write(' ${n(s.mergedConversations, 'existing conversation')} received missing messages.');
  }
  final int skipped = s.duplicateConversations + s.duplicateMessages + s.duplicateMemories;
  if (skipped > 0) {
    b.write(' Skipped as already present: ${n(s.duplicateConversations, 'conversation')}, '
        '${n(s.duplicateMessages, 'message')}, ${n(s.duplicateMemories, 'memory', 'memories')}.');
  }
  if (s.conflictingMessages > 0) {
    b.write(
      ' ${n(s.conflictingMessages, 'message')} skipped because their ids already belong to other chats.',
    );
  }
  if (s.settingsApplied) b.write(' Memory settings were applied.');
  return b.toString();
}
