import 'dart:convert';
import 'dart:typed_data';

import '../models/conversation.dart';
import 'backup_codec.dart';
import 'backup_crypto.dart';
import 'backup_models.dart';
import 'transcript_formats.dart';

/// Which reader understood a file. Only formats that are implemented AND
/// covered by tests are listed: there is deliberately no adapter for any
/// third-party chat application's export.
enum ImportSource {
  almusBackupZip('ALMUS complete backup (ZIP)'),
  almusEncryptedBackup('ALMUS encrypted backup'),
  almusJson('ALMUS structured JSON export'),
  genericJson('Generic JSON conversations (documented format)'),
  almusTxt('ALMUS plain-text transcript'),
  almusMarkdown('ALMUS Markdown transcript'),
  plainTranscript('Plain "You: / Assistant:" transcript');

  const ImportSource(this.label);

  final String label;
}

/// The result of reading and validating a file. Nothing is stored yet.
class ParsedImport {
  const ParsedImport({
    required this.source,
    required this.bundle,
    this.encrypted = false,
  });

  final ImportSource source;
  final BackupBundle bundle;
  final bool encrypted;
}

/// Reads any supported file into a [BackupBundle] without touching storage.
class ImportService {
  ImportService({BackupCrypto? crypto, BackupCodec? codec, DateTime Function()? clock})
      : _crypto = crypto ?? BackupCrypto(),
        _codec = codec ?? const BackupCodec(),
        _clock = clock ?? DateTime.now;

  final BackupCrypto _crypto;
  final BackupCodec _codec;
  final DateTime Function() _clock;

  /// True when the file is an encrypted backup (needs a password).
  bool isEncrypted(Uint8List bytes) => BackupCrypto.looksEncrypted(bytes);

  /// Reads [bytes]. For an encrypted backup pass [password]; without it a
  /// [BackupException] with code passwordRequired is thrown.
  Future<ParsedImport> inspect(
    Uint8List bytes, {
    String fileName = '',
    String? password,
  }) async {
    if (bytes.isEmpty) {
      throw const BackupException('This file is empty.');
    }
    if (bytes.length > kMaxInputBytes) {
      throw const BackupException(
        'This file is too large to import.',
        BackupErrorCode.tooLarge,
      );
    }

    if (BackupCrypto.looksEncrypted(bytes)) {
      if (password == null || password.isEmpty) {
        throw const BackupException(
          'This backup is password-protected. Enter its password.',
          BackupErrorCode.passwordRequired,
        );
      }
      final Uint8List inner = await _crypto.decrypt(bytes, password);
      final BackupBundle bundle = _codec.decodeZip(inner);
      return ParsedImport(
        source: ImportSource.almusEncryptedBackup,
        bundle: bundle,
        encrypted: true,
      );
    }

    if (_isZip(bytes)) {
      return ParsedImport(
        source: ImportSource.almusBackupZip,
        bundle: _codec.decodeZip(bytes),
      );
    }

    final String text = _decodeText(bytes);
    final String head = text.trimLeft();

    if (head.startsWith('{') || head.startsWith('[')) {
      return _parseJson(head);
    }
    if (head.startsWith(kTxtMagic)) {
      final List<BackupConversation> list = parseAlmusTxt(text);
      return ParsedImport(
        source: ImportSource.almusTxt,
        bundle: _finish(BackupBundle(conversations: list)),
      );
    }
    if (head.contains('<!-- almus:conversation ')) {
      final List<BackupConversation> list = parseAlmusMarkdown(text);
      return ParsedImport(
        source: ImportSource.almusMarkdown,
        bundle: _finish(BackupBundle(conversations: list)),
      );
    }

    final List<String> warnings = <String>[];
    final BackupConversation conversation = parsePlainTranscript(
      text,
      title: _titleFromFileName(fileName),
      now: _clock().toUtc(),
      warnings: warnings,
    );
    return ParsedImport(
      source: ImportSource.plainTranscript,
      bundle: _finish(
        BackupBundle(
          conversations: <BackupConversation>[conversation],
          warnings: warnings,
        ),
      ),
    );
  }

  static bool _isZip(Uint8List b) =>
      b.length >= 4 && b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04;

  static String _decodeText(Uint8List bytes) {
    // A NUL byte means binary data, not a text transcript.
    final int probe = bytes.length < 4096 ? bytes.length : 4096;
    for (int i = 0; i < probe; i++) {
      if (bytes[i] == 0) {
        throw const BackupException(
          'This file is not a text or backup file that ALMUS AI can read.',
          BackupErrorCode.unsupportedFormat,
        );
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const BackupException(
        'This text file is not valid UTF-8, so characters could be lost. Save it as UTF-8 and try again.',
      );
    }
  }

  static String _titleFromFileName(String name) {
    final String base = name.split('/').last;
    final int dot = base.lastIndexOf('.');
    final String stem = dot > 0 ? base.substring(0, dot) : base;
    return cleanTitle(stem.replaceAll(RegExp(r'[_-]+'), ' ')) ?? 'Imported chat';
  }

  ParsedImport _parseJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const BackupException(
        'This file is not valid JSON. It may be damaged, cut off, or edited incorrectly.',
      );
    }

    if (decoded is Map && decoded.containsKey('format')) {
      final Object? format = decoded['format'];
      if (format == kExportFormatId) {
        final BackupBundle bundle =
            BackupBundle.fromExportJson(asJsonMap(decoded, 'file'));
        return ParsedImport(
          source: ImportSource.almusJson,
          bundle: _finish(bundle),
        );
      }
      if (format == kBackupFormatId) {
        throw const BackupException(
          'This is the manifest of a backup, not the backup itself. Choose the ZIP file.',
          BackupErrorCode.unsupportedFormat,
        );
      }
      throw const BackupException(
        'This JSON file declares a format that ALMUS AI does not support.',
        BackupErrorCode.unsupportedFormat,
      );
    }

    final List<String> warnings = <String>[];
    final List<BackupConversation> conversations =
        _parseGenericJson(decoded, warnings);
    return ParsedImport(
      source: ImportSource.genericJson,
      bundle: _finish(
        BackupBundle(conversations: conversations, warnings: warnings),
      ),
    );
  }

  /// Final checks shared by every text adapter.
  BackupBundle _finish(BackupBundle bundle) {
    for (final BackupConversation c in bundle.conversations) {
      if (c.id.length > kMaxIdLength) {
        throw const BackupException('A conversation id in this file is too long.');
      }
      for (final BackupMessage m in c.messages) {
        if (m.id.length > kMaxIdLength || m.id.isEmpty) {
          throw const BackupException('A message id in this file is missing or too long.');
        }
      }
    }
    bundle.validate();
    return BackupBundle(
      conversations: bundle.conversations,
      memories: bundle.memories,
      settings: bundle.settings,
      appVersion: bundle.appVersion,
      schemaVersion: bundle.schemaVersion,
      exportedAt: bundle.exportedAt,
      warnings: bundle.warnings.toSet().toList(),
    );
  }

  // ------------------------------------------------- generic JSON adapter

  /// Documented generic format (see docs/BACKUP_FORMAT.md):
  ///
  ///   {"conversations": [ {"id"?, "title"?, "created_at"?, "messages": [...]} ]}
  ///   [ {"title"?, "messages": [...]}, ... ]
  ///   {"title"?, "messages": [...]}
  ///   [ {"role", "content"}, ... ]
  ///
  /// A message has "role" ("user" or "assistant"), "content" (or "text") and
  /// optionally "id" and "timestamp" / "created_at" (ISO-8601 or Unix time).
  List<BackupConversation> _parseGenericJson(Object? root, List<String> warnings) {
    final List<Object?> rawConversations;
    if (root is List) {
      if (root.isNotEmpty && root.every((Object? e) => e is Map && e.containsKey('messages'))) {
        rawConversations = root;
      } else {
        rawConversations = <Object?>[
          <String, Object?>{'messages': root},
        ];
      }
    } else if (root is Map) {
      if (root['conversations'] is List) {
        rawConversations = root['conversations']! as List<Object?>;
      } else if (root['messages'] is List) {
        rawConversations = <Object?>[root];
      } else {
        throw const BackupException(
          'This JSON file has no "conversations" or "messages" list, so ALMUS AI cannot tell what it contains. See the documented generic format.',
          BackupErrorCode.unsupportedFormat,
        );
      }
    } else {
      throw const BackupException(
        'This JSON file is not a list or object of conversations.',
        BackupErrorCode.unsupportedFormat,
      );
    }

    final DateTime now = _clock().toUtc();
    int skippedSystem = 0;
    int skippedOther = 0;
    bool missingTime = false;
    final List<BackupConversation> result = <BackupConversation>[];

    for (int ci = 0; ci < rawConversations.length; ci++) {
      final Map<String, Object?> conv =
          asJsonMap(rawConversations[ci], 'conversations[$ci]');
      final List<Object?> rawMessages =
          asJsonList(conv['messages'] ?? <Object?>[], 'conversations[$ci].messages');

      final List<_GenericMessage> kept = <_GenericMessage>[];
      for (int mi = 0; mi < rawMessages.length; mi++) {
        final Object? item = rawMessages[mi];
        if (item is! Map) {
          skippedOther++;
          continue;
        }
        final Object? roleRaw = item['role'];
        final String role = roleRaw is String ? roleRaw.toLowerCase() : '';
        if (role == 'system') {
          skippedSystem++;
          continue;
        }
        if (role != 'user' && role != 'assistant') {
          skippedOther++;
          continue;
        }
        final Object? content = item['content'] ?? item['text'];
        if (content is! String) {
          skippedOther++;
          continue;
        }
        final DateTime? at =
            _flexibleTime(item['timestamp'] ?? item['created_at'] ?? item['time']);
        if (at == null) missingTime = true;
        final Object? id = item['id'];
        kept.add(
          _GenericMessage(
            role: role,
            content: content,
            at: at,
            id: id is String && id.isNotEmpty ? id : null,
          ),
        );
      }

      final Object? rawTitle = conv['title'];
      final String title =
          cleanTitle(rawTitle is String ? rawTitle : '') ??
              (kept.isEmpty ? kDefaultTitle : titleFromMessage(kept.first.content));

      final List<BackupMessage> drafts = <BackupMessage>[
        for (int k = 0; k < kept.length; k++)
          BackupMessage(
            id: kept[k].id ?? '',
            conversationId: '',
            role: kept[k].role,
            content: kept[k].content,
            createdAt: kept[k].at ?? now.add(Duration(milliseconds: k)),
          ),
      ];
      final Object? rawId = conv['id'];
      final String id = rawId is String && rawId.trim().isNotEmpty
          ? rawId
          : importedConversationId(drafts, title);
      final List<BackupMessage> messages = <BackupMessage>[
        for (int k = 0; k < drafts.length; k++)
          BackupMessage(
            id: drafts[k].id.isEmpty ? '$id-m$k' : drafts[k].id,
            conversationId: id,
            role: drafts[k].role,
            content: drafts[k].content,
            createdAt: drafts[k].createdAt,
          ),
      ];
      final DateTime first = messages.isEmpty ? now : messages.first.createdAt;
      final DateTime last = messages.isEmpty ? now : messages.last.createdAt;
      result.add(
        BackupConversation(
          id: id,
          title: title,
          createdAt: _flexibleTime(conv['created_at']) ?? first,
          updatedAt: _flexibleTime(conv['updated_at']) ?? last,
          messages: messages,
        ),
      );
    }

    final int total = result.fold<int>(0, (int s, BackupConversation c) => s + c.messages.length);
    if (total == 0) {
      throw const BackupException(
        'No usable messages were found. Each message needs a "role" of "user" or "assistant" and text in "content".',
      );
    }
    if (skippedSystem > 0) {
      warnings.add('$skippedSystem system message(s) were skipped.');
    }
    if (skippedOther > 0) {
      warnings.add(
        '$skippedOther message(s) were skipped because their role or content is not supported.',
      );
    }
    if (missingTime) {
      warnings.add(
        'Some messages had no timestamp; the import time was used for them.',
      );
    }
    return result;
  }

  static DateTime? _flexibleTime(Object? value) {
    if (value is String) return parseIsoTime(value);
    if (value is num) {
      final double v = value.toDouble();
      if (v <= 0) return null;
      // Values above 1e11 are milliseconds; smaller ones are seconds.
      final int ms = v > 1e11 ? v.round() : (v * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    return null;
  }
}

class _GenericMessage {
  const _GenericMessage({
    required this.role,
    required this.content,
    required this.at,
    required this.id,
  });

  final String role;
  final String content;
  final DateTime? at;
  final String? id;
}
