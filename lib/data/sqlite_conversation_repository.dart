import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../utils/ids.dart';
import 'app_database.dart';
import 'conversation_repository.dart';
import 'storage_exception.dart';

/// SQLite implementation of [ConversationRepository].
/// Database errors are converted to [StorageException] with a generic message
/// so message text never leaks into error output.
class SqliteConversationRepository implements ConversationRepository {
  SqliteConversationRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on StorageException {
      rethrow;
    } on DatabaseException {
      throw const StorageException('The local database reported an error.');
    } on StateError {
      throw const StorageException('The local database is not available.');
    }
  }

  static String _escapeLike(String input) => input
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  Conversation _conversationFromRow(Map<String, Object?> row) {
    return Conversation(
      id: row['id']! as String,
      title: row['title']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      messageCount: (row['message_count'] as int?) ?? 0,
      preview: (row['preview'] as String?) ?? '',
    );
  }

  @override
  Future<Conversation> createConversation({
    String? id,
    String? title,
    DateTime? createdAt,
  }) {
    return _guard(() async {
      final DateTime time = createdAt ?? DateTime.now();
      final Conversation conversation = Conversation(
        id: id ?? newId('c'),
        title: cleanTitle(title ?? '') ?? kDefaultTitle,
        createdAt: time,
        updatedAt: time,
      );
      await _db.insert('conversations', <String, Object?>{
        'id': conversation.id,
        'title': conversation.title,
        'created_at': time.millisecondsSinceEpoch,
        'updated_at': time.millisecondsSinceEpoch,
      });
      return conversation;
    });
  }

  @override
  Future<Conversation?> getConversation(String id) {
    return _guard(() async {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
SELECT c.id, c.title, c.created_at, c.updated_at,
  (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count,
  (SELECT m.content FROM messages m WHERE m.conversation_id = c.id
     ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) AS preview
FROM conversations c WHERE c.id = ?''',
        <Object?>[id],
      );
      return rows.isEmpty ? null : _conversationFromRow(rows.first);
    });
  }

  @override
  Future<List<Conversation>> listConversations({
    String query = '',
    int limit = 200,
  }) {
    return _guard(() async {
      final List<Object?> args = <Object?>[];
      String where = '';
      final String q = query.trim();
      if (q.isNotEmpty) {
        final String like = '%${_escapeLike(q)}%';
        where = r'''
WHERE c.title LIKE ? ESCAPE '\'
   OR EXISTS (SELECT 1 FROM messages s WHERE s.conversation_id = c.id
              AND s.content LIKE ? ESCAPE '\')''';
        args.addAll(<Object?>[like, like]);
      }
      args.add(limit);
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
SELECT c.id, c.title, c.created_at, c.updated_at,
  (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count,
  (SELECT m.content FROM messages m WHERE m.conversation_id = c.id
     ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) AS preview
FROM conversations c
$where
ORDER BY c.updated_at DESC, c.rowid DESC
LIMIT ?''',
        args,
      );
      return rows.map(_conversationFromRow).toList();
    });
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    final String? cleaned = cleanTitle(title);
    if (cleaned == null) {
      throw const StorageException('A conversation title cannot be empty.');
    }
    return _guard(() async {
      final int changed = await _db.update(
        'conversations',
        <String, Object?>{'title': cleaned},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      if (changed == 0) {
        throw const StorageException('That conversation no longer exists.');
      }
    });
  }

  @override
  Future<void> deleteConversation(String id) {
    return _guard(() async {
      await _db.transaction((Transaction txn) async {
        await txn.delete('messages', where: 'conversation_id = ?', whereArgs: <Object?>[id]);
        await txn.delete('conversations', where: 'id = ?', whereArgs: <Object?>[id]);
      });
    });
  }

  @override
  Future<void> clearAll() {
    return _guard(() async {
      await _db.transaction((Transaction txn) async {
        await txn.delete('messages');
        await txn.delete('conversations');
      });
    });
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) {
    return _guard(() async {
      final int time = message.timestamp.millisecondsSinceEpoch;
      await _db.transaction((Transaction txn) async {
        await txn.insert('messages', <String, Object?>{
          'id': message.id,
          'conversation_id': message.conversationId,
          'role': message.role,
          'content': message.text,
          'created_at': time,
          'status': message.status.name,
          'engine': message.engineLabel,
        });
        await txn.rawUpdate(
          'UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?',
          <Object?>[time, message.conversationId],
        );
      });
      return message;
    });
  }

  @override
  Future<List<ChatMessage>> loadMessages(String conversationId) {
    return _guard(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: <Object?>[conversationId],
        orderBy: 'created_at ASC, rowid ASC',
      );
      return rows.map((Map<String, Object?> row) {
        return ChatMessage(
          id: row['id']! as String,
          conversationId: row['conversation_id']! as String,
          sender: row['role'] == 'user' ? MessageSender.user : MessageSender.assistant,
          text: row['content']! as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
          isError: row['status'] == 'error',
          engineLabel: (row['engine'] as String?) ?? 'DEMO',
        );
      }).toList();
    });
  }

  @override
  Future<void> close() => _database.close();
}
