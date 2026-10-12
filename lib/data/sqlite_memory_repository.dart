import 'package:sqflite/sqflite.dart';

import '../models/memory_item.dart';
import 'app_database.dart';
import 'memory_repository.dart';
import 'storage_exception.dart';

/// SQLite implementation of [MemoryRepository]. Database errors become a
/// [StorageException] with a generic message, so memory text never leaks into
/// error output.
class SqliteMemoryRepository implements MemoryRepository {
  SqliteMemoryRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const String _enabledName = 'memory_enabled';

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

  MemoryItem _fromRow(Map<String, Object?> row) {
    return MemoryItem(
      id: row['id']! as String,
      category: MemoryCategory.fromKey(row['category']! as String) ??
          MemoryCategory.fact,
      text: row['text']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      sourceConversationId: row['source_conversation_id'] as String?,
      status: MemoryStatus.fromKey(row['status']! as String) ??
          MemoryStatus.suggested,
    );
  }

  Map<String, Object?> _toRow(MemoryItem item) {
    return <String, Object?>{
      'id': item.id,
      'category': item.category.key,
      'text': item.text,
      'created_at': item.createdAt.millisecondsSinceEpoch,
      'updated_at': item.updatedAt.millisecondsSinceEpoch,
      'source_conversation_id': item.sourceConversationId,
      'status': item.status.key,
    };
  }

  @override
  Future<List<MemoryItem>> list({
    MemoryStatus? status,
    MemoryCategory? category,
  }) {
    return _guard(() async {
      final List<String> where = <String>[];
      final List<Object?> args = <Object?>[];
      if (status != null) {
        where.add('status = ?');
        args.add(status.key);
      }
      if (category != null) {
        where.add('category = ?');
        args.add(category.key);
      }
      final List<Map<String, Object?>> rows = await _db.query(
        'memories',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'updated_at DESC, rowid DESC',
      );
      return rows.map(_fromRow).toList();
    });
  }

  @override
  Future<MemoryItem?> get(String id) {
    return _guard(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        'memories',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return rows.isEmpty ? null : _fromRow(rows.first);
    });
  }

  @override
  Future<MemoryItem> insert(MemoryItem item) {
    return _guard(() async {
      await _db.insert('memories', _toRow(item));
      return item;
    });
  }

  @override
  Future<MemoryItem> update(MemoryItem item) {
    return _guard(() async {
      final int count = await _db.update(
        'memories',
        _toRow(item),
        where: 'id = ?',
        whereArgs: <Object?>[item.id],
      );
      if (count == 0) {
        throw const StorageException('That memory no longer exists.');
      }
      return item;
    });
  }

  @override
  Future<bool> delete(String id) {
    return _guard(() async {
      final int count = await _db.delete(
        'memories',
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      return count > 0;
    });
  }

  @override
  Future<void> clearAll() {
    return _guard(() async {
      await _db.delete('memories');
    });
  }

  @override
  Future<bool> isEnabled() {
    return _guard(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        'memory_prefs',
        where: 'name = ?',
        whereArgs: <Object?>[_enabledName],
        limit: 1,
      );
      if (rows.isEmpty) return true;
      return rows.first['value'] != '0';
    });
  }

  @override
  Future<void> setEnabled(bool enabled) {
    return _guard(() async {
      await _db.insert(
        'memory_prefs',
        <String, Object?>{'name': _enabledName, 'value': enabled ? '1' : '0'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<bool> isConversationMemoryOff(String conversationId) {
    return _guard(() async {
      final List<Map<String, Object?>> rows = await _db.query(
        'memory_conversation_flags',
        where: 'conversation_id = ?',
        whereArgs: <Object?>[conversationId],
        limit: 1,
      );
      return rows.isNotEmpty;
    });
  }

  @override
  Future<void> setConversationMemoryOff(String conversationId, bool off) {
    return _guard(() async {
      if (off) {
        await _db.insert(
          'memory_conversation_flags',
          <String, Object?>{'conversation_id': conversationId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        await _db.delete(
          'memory_conversation_flags',
          where: 'conversation_id = ?',
          whereArgs: <Object?>[conversationId],
        );
      }
    });
  }

  @override
  Future<void> clearConversationFlags() {
    return _guard(() async {
      await _db.delete('memory_conversation_flags');
    });
  }
}
