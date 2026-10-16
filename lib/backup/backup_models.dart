import '../models/conversation.dart';
import '../models/memory_item.dart';

/// Identifier written into every complete backup manifest.
const String kBackupFormatId = 'almus-ai-backup';

/// Identifier written into every structured JSON export.
const String kExportFormatId = 'almus-ai-export';

/// Identifier written into the header of an encrypted backup.
const String kEncryptedFormatId = 'almus-ai-encrypted-backup';

/// Version of the data layout. Raise it only when the layout changes in a way
/// older readers cannot understand; readers refuse versions they do not know.
const int kBackupSchemaVersion = 1;

/// Largest backup file the app will open (bytes).
const int kMaxInputBytes = 256 * 1024 * 1024;

/// Largest total size of everything inside a ZIP backup (bytes). Protects
/// against "zip bombs".
const int kMaxUncompressedBytes = 512 * 1024 * 1024;

const int kMaxIdLength = 256;
const int kMaxImportedMemoryChars = 20000;

/// Why a backup operation failed. The UI shows [BackupException.message].
enum BackupErrorCode {
  invalidFile,
  unsupportedFormat,
  unsupportedVersion,
  corrupted,
  passwordRequired,
  wrongPassword,
  weakPassword,
  tooLarge,
  storage,
  busy,
}

/// A backup problem. [message] is safe to show to the user: it never contains
/// message text, memory text, passwords or keys.
class BackupException implements Exception {
  const BackupException(this.message, [this.code = BackupErrorCode.invalidFile]);

  final String message;
  final BackupErrorCode code;

  @override
  String toString() => 'BackupException(${code.name}): $message';
}

/// UTC ISO-8601 with millisecond precision, e.g. 2026-01-01T10:00:00.000Z.
String isoTime(DateTime time) => time.toUtc().toIso8601String();

/// Parses an ISO-8601 string. Returns null when it is not a valid time.
DateTime? parseIsoTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

BackupException _err(String where, String problem) =>
    BackupException('$where: $problem');

Map<String, Object?> asJsonMap(Object? value, String where) {
  if (value is Map) {
    return value.map(
      (Object? key, Object? v) => MapEntry<String, Object?>(key.toString(), v),
    );
  }
  throw _err(where, 'expected a JSON object.');
}

List<Object?> asJsonList(Object? value, String where) {
  if (value is List) return value;
  throw _err(where, 'expected a JSON list.');
}

String _requiredId(Object? value, String where) {
  if (value is! String || value.trim().isEmpty) {
    throw _err(where, 'a non-empty text id is required.');
  }
  if (value.length > kMaxIdLength) {
    throw _err(where, 'the id is longer than $kMaxIdLength characters.');
  }
  return value;
}

/// One stored message in backup form.
class BackupMessage {
  const BackupMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = 'sent',
    this.engine = 'DEMO',
    this.attachments = const <Map<String, Object?>>[],
  });

  final String id;
  final String conversationId;

  /// 'user' or 'assistant'.
  final String role;
  final String content;
  final DateTime createdAt;

  /// 'sent' or 'error'.
  final String status;
  final String engine;

  /// Reserved. The app has no attachment feature yet, so exports always write
  /// an empty list. Imported non-empty lists are ignored with a warning.
  final List<Map<String, Object?>> attachments;

  Map<String, Object?> toJson(int index) => <String, Object?>{
        'id': id,
        'conversation_id': conversationId,
        'index': index,
        'role': role,
        'content': content,
        'created_at': isoTime(createdAt),
        'status': status,
        'engine': engine,
        'attachments': attachments,
      };

  factory BackupMessage.fromJson(
    Map<String, Object?> json,
    String conversationId,
    String where, [
    List<String>? warnings,
  ]) {
    final String id = _requiredId(json['id'], '$where.id');
    final Object? declaredConversation = json['conversation_id'];
    if (declaredConversation != null && declaredConversation != conversationId) {
      throw _err(where, 'conversation_id does not match the conversation it is stored in.');
    }
    final Object? role = json['role'];
    if (role != 'user' && role != 'assistant') {
      throw _err(where, 'role must be "user" or "assistant".');
    }
    final Object? content = json['content'];
    if (content is! String) {
      throw _err(where, 'content must be text.');
    }
    final DateTime? created = parseIsoTime(json['created_at']);
    if (created == null) {
      throw _err(where, 'created_at is missing or is not an ISO-8601 time.');
    }
    final Object? status = json['status'] ?? 'sent';
    if (status != 'sent' && status != 'error') {
      throw _err(where, 'status must be "sent" or "error".');
    }
    final Object? engine = json['engine'] ?? 'DEMO';
    if (engine is! String || engine.isEmpty || engine.length > 64) {
      throw _err(where, 'engine must be short text.');
    }
    final Object? attachments = json['attachments'];
    if (attachments is List && attachments.isNotEmpty) {
      warnings?.add(
        'Attachments in this file were ignored: this version of ALMUS AI does not store attachments.',
      );
    }
    return BackupMessage(
      id: id,
      conversationId: conversationId,
      role: role as String,
      content: content,
      createdAt: created,
      status: status as String,
      engine: engine,
    );
  }
}

/// One conversation with its messages (oldest first).
class BackupConversation {
  const BackupConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<BackupMessage> messages;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'created_at': isoTime(createdAt),
        'updated_at': isoTime(updatedAt),
        'message_count': messages.length,
        'metadata': const <String, Object?>{},
        'messages': <Object?>[
          for (int i = 0; i < messages.length; i++) messages[i].toJson(i),
        ],
      };

  factory BackupConversation.fromJson(
    Map<String, Object?> json,
    String where, [
    List<String>? warnings,
  ]) {
    final String id = _requiredId(json['id'], '$where.id');
    final Object? rawTitle = json['title'];
    final String title =
        cleanTitle(rawTitle is String ? rawTitle : '') ?? kDefaultTitle;
    final DateTime? created = parseIsoTime(json['created_at']);
    if (created == null) {
      throw _err(where, 'created_at is missing or is not an ISO-8601 time.');
    }
    final DateTime? updated = parseIsoTime(json['updated_at']);
    if (updated == null) {
      throw _err(where, 'updated_at is missing or is not an ISO-8601 time.');
    }
    final List<Object?> rawMessages =
        asJsonList(json['messages'] ?? <Object?>[], '$where.messages');
    final List<BackupMessage> messages = <BackupMessage>[];
    for (int i = 0; i < rawMessages.length; i++) {
      final String at = '$where.messages[$i]';
      messages.add(
        BackupMessage.fromJson(asJsonMap(rawMessages[i], at), id, at, warnings),
      );
    }
    return BackupConversation(
      id: id,
      title: title,
      createdAt: created,
      updatedAt: updated,
      messages: messages,
    );
  }
}

/// One personal memory in backup form.
class BackupMemory {
  const BackupMemory({
    required this.id,
    required this.category,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.sourceConversationId,
    this.status = 'confirmed',
  });

  final String id;

  /// A [MemoryCategory.key].
  final String category;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? sourceConversationId;

  /// 'confirmed' (approved by the user) or 'suggested'.
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'category': category,
        'text': text,
        'created_at': isoTime(createdAt),
        'updated_at': isoTime(updatedAt),
        'source_conversation_id': sourceConversationId,
        'status': status,
        'metadata': const <String, Object?>{},
      };

  factory BackupMemory.fromJson(Map<String, Object?> json, String where) {
    final String id = _requiredId(json['id'], '$where.id');
    final Object? category = json['category'];
    if (category is! String || MemoryCategory.fromKey(category) == null) {
      throw _err(where, 'category is missing or unknown.');
    }
    final Object? text = json['text'];
    if (text is! String || text.trim().isEmpty) {
      throw _err(where, 'text must be non-empty.');
    }
    if (text.length > kMaxImportedMemoryChars) {
      throw _err(where, 'text is too long.');
    }
    final DateTime? created = parseIsoTime(json['created_at']);
    final DateTime? updated = parseIsoTime(json['updated_at']);
    if (created == null || updated == null) {
      throw _err(where, 'created_at / updated_at must be ISO-8601 times.');
    }
    final Object? status = json['status'] ?? 'confirmed';
    if (status is! String || MemoryStatus.fromKey(status) == null) {
      throw _err(where, 'status must be "confirmed" or "suggested".');
    }
    final Object? source = json['source_conversation_id'];
    if (source != null && (source is! String || source.length > kMaxIdLength)) {
      throw _err(where, 'source_conversation_id must be text.');
    }
    return BackupMemory(
      id: id,
      category: category,
      text: text,
      createdAt: created,
      updatedAt: updated,
      sourceConversationId: source as String?,
      status: status,
    );
  }

  /// Key used to spot the same memory stored under a different id.
  String get duplicateKey => memoryDuplicateKey(category, text);
}

/// Same category and (case/space-insensitive) text means the same memory.
String memoryDuplicateKey(String category, String text) =>
    '$category|${text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()}';

/// The few user settings that belong to the stored data. Credentials, the
/// backend address, the app-lock and voice choices are deliberately NOT part
/// of a backup.
class BackupSettings {
  const BackupSettings({
    this.memoryEnabled,
    this.conversationMemoryOff = const <String>[],
  });

  /// The master memory switch (null = unknown / default).
  final bool? memoryEnabled;

  /// Conversation ids that have memory switched off.
  final List<String> conversationMemoryOff;

  Map<String, Object?> toJson() => <String, Object?>{
        'memory_enabled': memoryEnabled,
        'conversation_memory_off': conversationMemoryOff,
      };

  factory BackupSettings.fromJson(Map<String, Object?> json) {
    final Object? enabled = json['memory_enabled'];
    if (enabled != null && enabled is! bool) {
      throw _err('settings', 'memory_enabled must be true or false.');
    }
    final List<String> off = <String>[];
    for (final Object? id
        in asJsonList(json['conversation_memory_off'] ?? <Object?>[], 'settings.conversation_memory_off')) {
      off.add(_requiredId(id, 'settings.conversation_memory_off'));
    }
    return BackupSettings(
      memoryEnabled: enabled as bool?,
      conversationMemoryOff: off,
    );
  }
}

/// Everything a backup or import file can carry, in memory.
class BackupBundle {
  const BackupBundle({
    this.conversations = const <BackupConversation>[],
    this.memories = const <BackupMemory>[],
    this.settings,
    this.appVersion = '',
    this.schemaVersion = kBackupSchemaVersion,
    this.exportedAt,
    this.warnings = const <String>[],
  });

  final List<BackupConversation> conversations;
  final List<BackupMemory> memories;
  final BackupSettings? settings;

  /// App version that wrote the file (empty when unknown).
  final String appVersion;
  final int schemaVersion;
  final DateTime? exportedAt;

  /// Non-fatal problems found while reading the file.
  final List<String> warnings;

  int get messageCount => conversations.fold<int>(
        0,
        (int sum, BackupConversation c) => sum + c.messages.length,
      );

  bool get isEmpty =>
      conversations.isEmpty && memories.isEmpty && settings == null;

  BackupBundle copyWith({
    List<BackupConversation>? conversations,
    List<BackupMemory>? memories,
    BackupSettings? settings,
    bool clearSettings = false,
    List<String>? warnings,
  }) {
    return BackupBundle(
      conversations: conversations ?? this.conversations,
      memories: memories ?? this.memories,
      settings: clearSettings ? null : (settings ?? this.settings),
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      exportedAt: exportedAt,
      warnings: warnings ?? this.warnings,
    );
  }

  /// Throws a [BackupException] when ids repeat, because the database would
  /// reject such a file half-way through.
  void validate() {
    final Set<String> conversationIds = <String>{};
    final Set<String> messageIds = <String>{};
    for (final BackupConversation c in conversations) {
      if (!conversationIds.add(c.id)) {
        throw const BackupException(
          'This file lists the same conversation id twice, so it cannot be imported safely.',
        );
      }
      for (final BackupMessage m in c.messages) {
        if (!messageIds.add(m.id)) {
          throw const BackupException(
            'This file uses the same message id twice, so it cannot be imported safely.',
          );
        }
      }
    }
    final Set<String> memoryIds = <String>{};
    for (final BackupMemory m in memories) {
      if (!memoryIds.add(m.id)) {
        throw const BackupException(
          'This file lists the same memory id twice, so it cannot be imported safely.',
        );
      }
    }
  }

  /// Structured export document. [kind] is "conversations", "memories" or "all".
  Map<String, Object?> toExportJson({
    required String kind,
    required String appVersion,
    required DateTime exportedAt,
  }) {
    return <String, Object?>{
      'format': kExportFormatId,
      'schema_version': kBackupSchemaVersion,
      'kind': kind,
      'app_version': appVersion,
      'exported_at': isoTime(exportedAt),
      if (kind != 'memories')
        'conversations': <Object?>[
          for (final BackupConversation c in conversations) c.toJson(),
        ],
      if (kind != 'conversations')
        'memories': <Object?>[
          for (final BackupMemory m in memories) m.toJson(),
        ],
      if (settings != null) 'settings': settings!.toJson(),
    };
  }

  /// Reads a document written by [toExportJson].
  factory BackupBundle.fromExportJson(Map<String, Object?> json) {
    final Object? version = json['schema_version'];
    if (version is! int || version < 1) {
      throw const BackupException('The file has no valid schema_version.');
    }
    if (version > kBackupSchemaVersion) {
      throw BackupException(
        'This file uses backup format version $version, which is newer than this app understands (version $kBackupSchemaVersion). Update ALMUS AI and try again.',
        BackupErrorCode.unsupportedVersion,
      );
    }
    final List<String> warnings = <String>[];
    return BackupBundle.fromParts(
      conversations: json['conversations'],
      memories: json['memories'],
      settings: json['settings'],
      appVersion: json['app_version'] is String ? json['app_version']! as String : '',
      schemaVersion: version,
      exportedAt: parseIsoTime(json['exported_at']),
      warnings: warnings,
    );
  }

  /// Builds a bundle from the already-decoded JSON parts. Shared by the
  /// structured export reader and the ZIP backup reader.
  factory BackupBundle.fromParts({
    Object? conversations,
    Object? memories,
    Object? settings,
    String appVersion = '',
    int schemaVersion = kBackupSchemaVersion,
    DateTime? exportedAt,
    List<String>? warnings,
  }) {
    final List<String> notes = warnings ?? <String>[];
    final List<BackupConversation> parsedConversations = <BackupConversation>[];
    if (conversations != null) {
      final List<Object?> list = asJsonList(conversations, 'conversations');
      for (int i = 0; i < list.length; i++) {
        final String where = 'conversations[$i]';
        parsedConversations.add(
          BackupConversation.fromJson(asJsonMap(list[i], where), where, notes),
        );
      }
    }
    final List<BackupMemory> parsedMemories = <BackupMemory>[];
    if (memories != null) {
      final List<Object?> list = asJsonList(memories, 'memories');
      for (int i = 0; i < list.length; i++) {
        final String where = 'memories[$i]';
        parsedMemories.add(BackupMemory.fromJson(asJsonMap(list[i], where), where));
      }
    }
    final BackupBundle bundle = BackupBundle(
      conversations: parsedConversations,
      memories: parsedMemories,
      settings: settings == null
          ? null
          : BackupSettings.fromJson(asJsonMap(settings, 'settings')),
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      exportedAt: exportedAt,
      warnings: _dedupe(notes),
    );
    bundle.validate();
    return bundle;
  }
}

List<String> _dedupe(List<String> items) => items.toSet().toList();
