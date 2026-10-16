import 'dart:convert';

import '../models/conversation.dart';
import 'backup_codec.dart';
import 'backup_models.dart';

/// The readable / structured formats a conversation can be exported in.
enum TranscriptFormat {
  json('JSON (structured, lossless)', 'json', 'application/json'),
  markdown('Markdown (readable)', 'md', 'text/markdown'),
  txt('Plain text (readable)', 'txt', 'text/plain');

  const TranscriptFormat(this.label, this.extension, this.mimeType);

  final String label;
  final String extension;
  final String mimeType;
}

/// Formats for the personal-memory export.
enum MemoryExportFormat {
  json('JSON (structured, lossless)', 'json'),
  markdown('Markdown (readable)', 'md');

  const MemoryExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

const String _eq = '================================================================';
const String _dash = '----------------------------------------------------------------';
const String kTxtMagic = 'ALMUS AI conversation transcript';
const String kMarkdownMagic = '<!-- almus:export ';

String _speaker(String role) => role == 'user' ? 'You' : 'Almus';

String _humanTime(DateTime t) {
  final DateTime u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} UTC';
}

/// Escapes `<` and `>` so JSON inside an HTML comment can never end the comment.
String _commentJson(Map<String, Object?> value) =>
    jsonEncode(value).replaceAll('<', r'\u003c').replaceAll('>', r'\u003e');

// ---------------------------------------------------------------- writers

/// Structured, lossless JSON (pretty-printed so it can also be read by eye).
String conversationsToJson(
  List<BackupConversation> conversations, {
  required String appVersion,
  required DateTime exportedAt,
}) {
  final BackupBundle bundle = BackupBundle(conversations: conversations);
  return const JsonEncoder.withIndent('  ').convert(
    bundle.toExportJson(
      kind: 'conversations',
      appVersion: appVersion,
      exportedAt: exportedAt,
    ),
  );
}

/// Structured JSON for memories.
String memoriesToJson(
  List<BackupMemory> memories, {
  required String appVersion,
  required DateTime exportedAt,
}) {
  final BackupBundle bundle = BackupBundle(memories: memories);
  return const JsonEncoder.withIndent('  ').convert(
    bundle.toExportJson(
      kind: 'memories',
      appVersion: appVersion,
      exportedAt: exportedAt,
    ),
  );
}

/// Readable plain-text transcript. Message text is indented by four spaces so
/// the file can be read back by [parseAlmusTxt].
String conversationsToTxt(
  List<BackupConversation> conversations, {
  required String appVersion,
  required DateTime exportedAt,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln(kTxtMagic)
    ..writeln('Format: almus-transcript-txt 1')
    ..writeln('Exported: ${isoTime(exportedAt)}')
    ..writeln('App version: $appVersion')
    ..writeln('Conversations: ${conversations.length}');
  for (final BackupConversation c in conversations) {
    b
      ..writeln()
      ..writeln(_eq)
      ..writeln('Title: ${c.title}')
      ..writeln('Conversation ID: ${c.id}')
      ..writeln('Created: ${isoTime(c.createdAt)}')
      ..writeln('Updated: ${isoTime(c.updatedAt)}')
      ..writeln('Messages: ${c.messages.length}')
      ..writeln(_dash);
    if (c.messages.isEmpty) b.writeln('(no messages)');
    for (final BackupMessage m in c.messages) {
      b
        ..writeln()
        ..writeln(
          '[${isoTime(m.createdAt)}] ${_speaker(m.role)} (${m.role}) | id: ${m.id} | engine: ${m.engine} | status: ${m.status}',
        );
      for (final String line in m.content.split('\n')) {
        b.writeln('    $line');
      }
    }
  }
  return b.toString();
}

/// Readable Markdown transcript. Hidden HTML comments carry the ids and
/// timestamps so the file can be read back by [parseAlmusMarkdown].
String conversationsToMarkdown(
  List<BackupConversation> conversations, {
  required String appVersion,
  required DateTime exportedAt,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('# ALMUS AI conversations')
    ..writeln(
      '$kMarkdownMagic${_commentJson(<String, Object?>{
            'format': 'almus-transcript-md',
            'version': 1,
            'exported_at': isoTime(exportedAt),
            'app_version': appVersion,
          })} -->',
    )
    ..writeln()
    ..writeln('_Exported ${_humanTime(exportedAt)} · ${conversations.length} conversation(s)_');
  for (final BackupConversation c in conversations) {
    b
      ..writeln()
      ..writeln(
        '<!-- almus:conversation ${_commentJson(<String, Object?>{
              'id': c.id,
              'title': c.title,
              'created_at': isoTime(c.createdAt),
              'updated_at': isoTime(c.updatedAt),
            })} -->',
      )
      ..writeln('## ${c.title}');
    if (c.messages.isEmpty) b..writeln()..writeln('_(no messages)_');
    for (final BackupMessage m in c.messages) {
      b
        ..writeln()
        ..writeln(
          '<!-- almus:message ${_commentJson(<String, Object?>{
                'id': m.id,
                'role': m.role,
                'created_at': isoTime(m.createdAt),
                'status': m.status,
                'engine': m.engine,
              })} -->',
        )
        ..writeln('### ${_speaker(m.role)} · ${_humanTime(m.createdAt)}')
        ..writeln();
      for (final String line in m.content.split('\n')) {
        b.writeln(line);
      }
      b.writeln();
    }
  }
  return b.toString();
}

/// Readable Markdown for memories (export only).
String memoriesToMarkdown(
  List<BackupMemory> memories, {
  required String appVersion,
  required DateTime exportedAt,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('# ALMUS AI personal memory')
    ..writeln()
    ..writeln('_Exported ${_humanTime(exportedAt)} · ${memories.length} memor${memories.length == 1 ? 'y' : 'ies'}_');
  if (memories.isEmpty) b..writeln()..writeln('_(no memories)_');
  for (final BackupMemory m in memories) {
    b
      ..writeln()
      ..writeln('- **${m.category}** (${m.status}) — ${m.text.replaceAll('\n', ' ')}')
      ..writeln('  - id: `${m.id}` · created ${_humanTime(m.createdAt)} · updated ${_humanTime(m.updatedAt)}');
  }
  return b.toString();
}

// ---------------------------------------------------------------- parsers

String deterministicId(String prefix, Iterable<String> parts) {
  final String joined = parts.join('\u0001');
  return '$prefix${sha256Hex(utf8.encode(joined)).substring(0, 32)}';
}

/// Id for a conversation that carries none, derived from its message content
/// so importing the same file twice finds the same id (and detects duplicates).
String importedConversationId(List<BackupMessage> messages, String title) {
  return deterministicId('imp-', <String>[
    if (messages.isEmpty) title,
    for (final BackupMessage m in messages) '${m.role}\u0000${m.content}',
  ]);
}

String _normalizeNewlines(String text) {
  String t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (t.startsWith('\uFEFF')) t = t.substring(1);
  return t;
}

final RegExp _txtMessageHeader = RegExp(
  r'^\[([^\]]+)\] (?:You|Almus) \((user|assistant)\)(?: \| id: (.*?))?(?: \| engine: (.*?))?(?: \| status: (sent|error))?\s*$',
);

/// Reads a transcript written by [conversationsToTxt].
List<BackupConversation> parseAlmusTxt(String raw) {
  final List<String> lines = _normalizeNewlines(raw).split('\n');
  final List<BackupConversation> result = <BackupConversation>[];

  int i = 0;
  while (i < lines.length) {
    if (lines[i] != _eq) {
      i++;
      continue;
    }
    i++;
    String title = kDefaultTitle;
    String? id;
    DateTime? created;
    DateTime? updated;
    while (i < lines.length && lines[i] != _dash) {
      final String line = lines[i];
      if (line.startsWith('Title: ')) {
        title = cleanTitle(line.substring(7)) ?? kDefaultTitle;
      } else if (line.startsWith('Conversation ID: ')) {
        id = line.substring(17).trim();
      } else if (line.startsWith('Created: ')) {
        created = parseIsoTime(line.substring(9).trim());
      } else if (line.startsWith('Updated: ')) {
        updated = parseIsoTime(line.substring(9).trim());
      }
      i++;
    }
    if (i >= lines.length) {
      throw const BackupException(
        'The transcript ends inside a conversation header.',
      );
    }
    i++; // the dash line

    final List<_RawMessage> raws = <_RawMessage>[];
    _RawMessage? current;
    int pendingBlank = 0;
    while (i < lines.length && lines[i] != _eq) {
      final String line = lines[i];
      final RegExpMatch? header = _txtMessageHeader.firstMatch(line);
      if (header != null) {
        final DateTime? at = parseIsoTime(header.group(1));
        if (at == null) {
          throw BackupException(
            'Line ${i + 1}: the message time "${header.group(1)}" is not a valid ISO-8601 time.',
          );
        }
        current = _RawMessage(
          at,
          header.group(2)!,
          header.group(3),
          header.group(4),
          header.group(5),
        );
        raws.add(current);
        pendingBlank = 0;
      } else if (current != null && line.startsWith('    ')) {
        for (int k = 0; k < pendingBlank; k++) {
          current.lines.add('');
        }
        pendingBlank = 0;
        current.lines.add(line.substring(4));
      } else if (line.trim().isEmpty) {
        pendingBlank++;
      } else if (line.trim() == '(no messages)') {
        // Empty conversation marker.
      } else {
        throw BackupException(
          'Line ${i + 1}: unexpected text outside a message. Message text must be indented by four spaces.',
        );
      }
      i++;
    }

    result.add(_buildConversation(id, title, created, updated, raws));
  }

  if (result.isEmpty) {
    throw const BackupException(
      'No conversations were found in this transcript.',
    );
  }
  return result;
}

class _RawMessage {
  _RawMessage(this.at, this.role, this.id, this.engine, this.status);

  final DateTime at;
  final String role;
  final String? id;
  final String? engine;
  final String? status;
  final List<String> lines = <String>[];
}

BackupConversation _buildConversation(
  String? id,
  String title,
  DateTime? created,
  DateTime? updated,
  List<_RawMessage> raws,
) {
  final List<BackupMessage> drafts = <BackupMessage>[
    for (final _RawMessage r in raws)
      BackupMessage(
        id: r.id ?? '',
        conversationId: '',
        role: r.role,
        content: r.lines.join('\n'),
        createdAt: r.at,
        status: r.status == 'error' ? 'error' : 'sent',
        engine: (r.engine == null || r.engine!.isEmpty || r.engine!.length > 64)
            ? 'DEMO'
            : r.engine!,
      ),
  ];
  final String conversationId = (id != null && id.isNotEmpty)
      ? id
      : importedConversationId(drafts, title);
  final List<BackupMessage> messages = <BackupMessage>[
    for (int k = 0; k < drafts.length; k++)
      BackupMessage(
        id: drafts[k].id.isEmpty ? '$conversationId-m$k' : drafts[k].id,
        conversationId: conversationId,
        role: drafts[k].role,
        content: drafts[k].content,
        createdAt: drafts[k].createdAt,
        status: drafts[k].status,
        engine: drafts[k].engine,
      ),
  ];
  final DateTime first = messages.isEmpty ? DateTime.now().toUtc() : messages.first.createdAt;
  final DateTime last = messages.isEmpty ? first : messages.last.createdAt;
  return BackupConversation(
    id: conversationId,
    title: title,
    createdAt: created ?? first,
    updatedAt: updated ?? last,
    messages: messages,
  );
}

final RegExp _mdMarker = RegExp(r'^<!-- almus:(conversation|message|export) (\{.*\}) -->$');

/// Reads a transcript written by [conversationsToMarkdown].
List<BackupConversation> parseAlmusMarkdown(String raw) {
  final List<String> lines = _normalizeNewlines(raw).split('\n');
  final List<BackupConversation> result = <BackupConversation>[];

  String? convId;
  String convTitle = kDefaultTitle;
  DateTime? convCreated;
  DateTime? convUpdated;
  final List<_RawMessage> raws = <_RawMessage>[];

  void flush() {
    if (convId == null) return;
    result.add(_buildConversation(convId, convTitle, convCreated, convUpdated, raws));
    raws.clear();
    convId = null;
  }

  int i = 0;
  while (i < lines.length) {
    final RegExpMatch? marker = _mdMarker.firstMatch(lines[i]);
    if (marker == null) {
      i++;
      continue;
    }
    final String kind = marker.group(1)!;
    final Map<String, Object?> data;
    try {
      data = asJsonMap(jsonDecode(marker.group(2)!), 'line ${i + 1}');
    } on Object {
      throw BackupException('Line ${i + 1}: an ALMUS marker is not valid.');
    }
    if (kind == 'conversation') {
      flush();
      final Object? id = data['id'];
      if (id is! String || id.isEmpty) {
        throw BackupException('Line ${i + 1}: the conversation marker has no id.');
      }
      convId = id;
      convTitle = cleanTitle(data['title'] is String ? data['title']! as String : '') ?? kDefaultTitle;
      convCreated = parseIsoTime(data['created_at']);
      convUpdated = parseIsoTime(data['updated_at']);
      i++;
    } else if (kind == 'message') {
      if (convId == null) {
        throw BackupException('Line ${i + 1}: a message appears before any conversation.');
      }
      final DateTime? at = parseIsoTime(data['created_at']);
      final Object? role = data['role'];
      if (at == null || (role != 'user' && role != 'assistant')) {
        throw BackupException('Line ${i + 1}: the message marker has no valid role or time.');
      }
      i++;
      // Skip the visible "### You · time" heading and the blank line after it.
      if (i < lines.length && lines[i].startsWith('### ')) i++;
      if (i < lines.length && lines[i].isEmpty) i++;
      final List<String> body = <String>[];
      while (i < lines.length && _mdMarker.firstMatch(lines[i]) == null) {
        body.add(lines[i]);
        i++;
      }
      // Remove the single blank separator line the writer adds.
      for (int k = 0; k < 2 && body.isNotEmpty && body.last.isEmpty; k++) {
        body.removeLast();
      }
      final _RawMessage m = _RawMessage(
        at,
        role! as String,
        data['id'] is String ? data['id']! as String : null,
        data['engine'] is String ? data['engine']! as String : null,
        data['status'] is String ? data['status']! as String : null,
      );
      m.lines.addAll(body);
      raws.add(m);
    } else {
      i++; // the export marker carries nothing the importer needs
    }
  }
  flush();

  if (result.isEmpty) {
    throw const BackupException('No conversations were found in this Markdown file.');
  }
  return result;
}

// Speaker lines used by the generic fallback ("User: hello").
final RegExp _speakerLine = RegExp(
  r'^\s*(?:#{1,6}\s*)?(?:\*\*|__)?(you|user|me|human|assistant|almus|ai|bot)(?:\*\*|__)?\s*[:：]\s*(?:\*\*|__)?\s?(.*)$',
  caseSensitive: false,
);

/// Documented fallback: a transcript with lines like "User: ..." and
/// "Assistant: ...". Continuation lines belong to the previous speaker. Times
/// are not available in this format, so the import time is used.
BackupConversation parsePlainTranscript(
  String raw, {
  required String title,
  required DateTime now,
  required List<String> warnings,
}) {
  final List<String> lines = _normalizeNewlines(raw).split('\n');
  final List<_RawMessage> raws = <_RawMessage>[];
  _RawMessage? current;
  bool ignoredIntro = false;
  for (final String line in lines) {
    final RegExpMatch? m = _speakerLine.firstMatch(line);
    if (m != null) {
      final String who = m.group(1)!.toLowerCase();
      final bool isUser = who == 'you' || who == 'user' || who == 'me' || who == 'human';
      current = _RawMessage(now, isUser ? 'user' : 'assistant', null, null, null);
      current.lines.add(m.group(2) ?? '');
      raws.add(current);
    } else if (current != null) {
      current.lines.add(line);
    } else if (line.trim().isNotEmpty) {
      ignoredIntro = true;
    }
  }
  if (raws.isEmpty) {
    throw const BackupException(
      'No messages were recognised. This importer understands lines that start with "You:", "User:", "Assistant:" or "Almus:", ALMUS AI transcripts, and the documented JSON format.',
    );
  }
  for (final _RawMessage r in raws) {
    // Drop blank lines at the end of each message.
    while (r.lines.length > 1 && r.lines.last.trim().isEmpty) {
      r.lines.removeLast();
    }
  }
  if (ignoredIntro) {
    warnings.add('Text before the first "You:" / "Assistant:" line was ignored.');
  }
  warnings.add('This format has no timestamps, so the import time was used for every message.');
  final List<BackupMessage> sequence = <BackupMessage>[
    for (int k = 0; k < raws.length; k++)
      BackupMessage(
        id: '',
        conversationId: '',
        role: raws[k].role,
        content: raws[k].lines.join('\n'),
        createdAt: now.add(Duration(milliseconds: k)),
      ),
  ];
  final String cleaned = cleanTitle(title) ?? kDefaultTitle;
  final String id = importedConversationId(sequence, cleaned);
  return BackupConversation(
    id: id,
    title: cleaned,
    createdAt: sequence.first.createdAt,
    updatedAt: sequence.last.createdAt,
    messages: <BackupMessage>[
      for (int k = 0; k < sequence.length; k++)
        BackupMessage(
          id: '$id-m$k',
          conversationId: id,
          role: sequence[k].role,
          content: sequence[k].content,
          createdAt: sequence[k].createdAt,
        ),
    ],
  );
}
