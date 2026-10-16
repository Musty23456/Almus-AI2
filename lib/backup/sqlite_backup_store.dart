import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';
import 'backup_models.dart';
import 'backup_store.dart';

/// SQLite implementation of [BackupStore]. It only touches the tables that
/// belong to backed-up data: conversations, messages, memories, the memory
/// master switch and the per-conversation memory flags. Nothing else in the
/// app (lock, voice, backend settings) is read or changed.
class SqliteBackupStore implements BackupStore {
  SqliteBackupStore(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const int _chunk = 500;
  static const String _enabledName = 'memory_enabled';

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on BackupException {
      rethrow;
    } on DatabaseException {
      throw const BackupException(
        'The local database reported an error. Nothing was changed.',
        BackupErrorCode.storage,
      );
    } on StateError {
      throw const BackupException(
        'The local database is not available.',
        BackupErrorCode.storage,
      );
    }
  }

  // ------------------------------------------------------------------ read

  Future<StoreCounts> _countsOn(DatabaseExecutor ex) async {
    Future<int> count(String table) async =>
        Sqflite.firstIntValue(await ex.rawQuery('SELECT COUNT(*) FROM $table')) ?? 0;
    return StoreCounts(
      conversations: await count('conversations'),
      messages: await count('messages'),
      memories: await count('memories'),
    );
  }

  @override
  Future<StoreCounts> counts() => _guard(() => _countsOn(_db));

  BackupMessage _message(Map<String, Object?> row) {
    return BackupMessage(
      id: row['id']! as String,
      conversationId: row['conversation_id']! as String,
      role: row['role']! as String,
      content: row['content']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
      status: (row['status'] as String?) ?? 'sent',
      engine: (row['engine'] as String?) ?? 'DEMO',
    );
  }

  Future<List<BackupConversation>> _readConversations(
    DatabaseExecutor ex,
    Set<String>? ids,
  ) async {
    final List<Map<String, Object?>> all = await ex.query(
      'conversations',
      orderBy: 'created_at ASC, rowid ASC',
    );
    final List<Map<String, Object?>> selected = ids == null
        ? all
        : all.where((Map<String, Object?> r) => ids.contains(r['id'])).toList();
    final Map<String, List<BackupMessage>> byConversation =
        <String, List<BackupMessage>>{
      for (final Map<String, Object?> r in selected)
        r['id']! as String: <BackupMessage>[],
    };

    if (ids == null) {
      final List<Map<String, Object?>> rows = await ex.query(
        'messages',
        orderBy: 'created_at ASC, rowid ASC',
      );
      for (final Map<String, Object?> row in rows) {
        byConversation[row['conversation_id']! as String]?.add(_message(row));
      }
    } else {
      final List<String> idList = byConversation.keys.toList();
      for (int i = 0; i < idList.length; i += _chunk) {
        final List<String> part = idList.sublist(i, min(i + _chunk, idList.length));
        final List<Map<String, Object?>> rows = await ex.query(
          'messages',
          where: 'conversation_id IN (${List<String>.filled(part.length, '?').join(',')})',
          whereArgs: part,
          orderBy: 'created_at ASC, rowid ASC',
        );
        for (final Map<String, Object?> row in rows) {
          byConversation[row['conversation_id']! as String]?.add(_message(row));
        }
      }
    }

    return <BackupConversation>[
      for (final Map<String, Object?> r in selected)
        BackupConversation(
          id: r['id']! as String,
          title: r['title']! as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int, isUtc: true),
          messages: byConversation[r['id']! as String]!,
        ),
    ];
  }

  Future<List<BackupMemory>> _readMemories(DatabaseExecutor ex) async {
    final List<Map<String, Object?>> rows = await ex.query(
      'memories',
      orderBy: 'created_at ASC, rowid ASC',
    );
    return <BackupMemory>[
      for (final Map<String, Object?> r in rows)
        BackupMemory(
          id: r['id']! as String,
          category: r['category']! as String,
          text: r['text']! as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int, isUtc: true),
          sourceConversationId: r['source_conversation_id'] as String?,
          status: (r['status'] as String?) ?? 'confirmed',
        ),
    ];
  }

  Future<BackupSettings> _readSettings(DatabaseExecutor ex) async {
    final List<Map<String, Object?>> prefs = await ex.query(
      'memory_prefs',
      where: 'name = ?',
      whereArgs: <Object?>[_enabledName],
      limit: 1,
    );
    final List<Map<String, Object?>> flags = await ex.query(
      'memory_conversation_flags',
      orderBy: 'conversation_id ASC',
    );
    return BackupSettings(
      memoryEnabled: prefs.isEmpty ? null : prefs.first['value'] != '0',
      conversationMemoryOff: <String>[
        for (final Map<String, Object?> f in flags) f['conversation_id']! as String,
      ],
    );
  }

  @override
  Future<BackupBundle> read({
    Set<String>? conversationIds,
    bool conversations = true,
    bool memories = true,
    bool settings = false,
  }) {
    return _guard(() {
      // One transaction gives a consistent snapshot of every table.
      return _db.transaction<BackupBundle>((Transaction txn) async {
        return BackupBundle(
          conversations:
              conversations ? await _readConversations(txn, conversationIds) : const <BackupConversation>[],
          memories: memories ? await _readMemories(txn) : const <BackupMemory>[],
          settings: settings ? await _readSettings(txn) : null,
        );
      });
    });
  }

  // ------------------------------------------------------------------ plan

  Future<Set<String>> _ids(DatabaseExecutor ex, String table) async {
    final List<Map<String, Object?>> rows = await ex.rawQuery('SELECT id FROM $table');
    return <String>{for (final Map<String, Object?> r in rows) r['id']! as String};
  }

  Future<_Plan> _buildPlan(
    DatabaseExecutor ex,
    BackupBundle bundle,
    ImportOptions options, {
    required bool assumeEmpty,
  }) async {
    final bool replace = options.mode == ImportMode.replace;
    final bool ignoreExistingConversations = assumeEmpty && replace && options.conversations;
    final bool ignoreExistingMemories = assumeEmpty && replace && options.memories;

    final Set<String> existingConversations =
        ignoreExistingConversations ? <String>{} : await _ids(ex, 'conversations');
    final Map<String, String> messageOwner = <String, String>{};
    if (!ignoreExistingConversations && options.conversations) {
      final List<Map<String, Object?>> rows =
          await ex.rawQuery('SELECT id, conversation_id FROM messages');
      for (final Map<String, Object?> r in rows) {
        messageOwner[r['id']! as String] = r['conversation_id']! as String;
      }
    }

    final _Plan plan = _Plan();
    int newConversations = 0;
    int mergedConversations = 0;
    int duplicateConversations = 0;
    int newMessages = 0;
    int duplicateMessages = 0;
    int conflictingMessages = 0;

    if (options.conversations) {
      for (final BackupConversation c in bundle.conversations) {
        final List<BackupMessage> fresh = <BackupMessage>[];
        for (final BackupMessage m in c.messages) {
          final String? owner = messageOwner[m.id];
          if (owner == null) {
            fresh.add(m);
          } else if (owner == c.id) {
            duplicateMessages++;
          } else {
            conflictingMessages++;
          }
        }
        final bool exists = existingConversations.contains(c.id);
        if (!exists) {
          newConversations++;
          newMessages += fresh.length;
          plan.newConversations.add(_NewConversation(c, fresh));
        } else if (fresh.isEmpty) {
          duplicateConversations++;
        } else {
          mergedConversations++;
          newMessages += fresh.length;
          plan.existingAdds.add(_ExistingAdd(c, fresh));
        }
      }
    }

    int newMemories = 0;
    int duplicateMemories = 0;
    if (options.memories) {
      final Set<String> existingIds =
          ignoreExistingMemories ? <String>{} : await _ids(ex, 'memories');
      final Set<String> keys = <String>{};
      if (!ignoreExistingMemories) {
        final List<Map<String, Object?>> rows =
            await ex.rawQuery('SELECT category, text FROM memories');
        for (final Map<String, Object?> r in rows) {
          keys.add(memoryDuplicateKey(r['category']! as String, r['text']! as String));
        }
      }
      for (final BackupMemory m in bundle.memories) {
        if (existingIds.contains(m.id) || keys.contains(m.duplicateKey)) {
          duplicateMemories++;
        } else {
          keys.add(m.duplicateKey);
          newMemories++;
          plan.newMemories.add(m);
        }
      }
    }

    bool settingsApplied = false;
    final BackupSettings? settings = bundle.settings;
    if (options.settings && settings != null) {
      settingsApplied = true;
      final Set<String> knownConversations = <String>{
        if (!ignoreExistingConversations) ...existingConversations,
        if (options.conversations)
          for (final BackupConversation c in bundle.conversations) c.id,
      };
      plan.flagsToAdd.addAll(
        settings.conversationMemoryOff.where(knownConversations.contains),
      );
      // Merge never changes the master memory switch the user has now.
      if (replace) plan.memoryEnabled = settings.memoryEnabled;
    }

    plan.summary = ImportSummary(
      newConversations: newConversations,
      mergedConversations: mergedConversations,
      duplicateConversations: duplicateConversations,
      newMessages: newMessages,
      duplicateMessages: duplicateMessages,
      conflictingMessages: conflictingMessages,
      newMemories: newMemories,
      duplicateMemories: duplicateMemories,
      settingsApplied: settingsApplied,
    );
    return plan;
  }

  @override
  Future<ImportSummary> plan(BackupBundle bundle, ImportOptions options) {
    return _guard(() async {
      final StoreCounts current = await _countsOn(_db);
      final _Plan p = await _buildPlan(_db, bundle, options, assumeEmpty: true);
      final ImportSummary s = p.summary;
      return ImportSummary(
        newConversations: s.newConversations,
        mergedConversations: s.mergedConversations,
        duplicateConversations: s.duplicateConversations,
        newMessages: s.newMessages,
        duplicateMessages: s.duplicateMessages,
        conflictingMessages: s.conflictingMessages,
        newMemories: s.newMemories,
        duplicateMemories: s.duplicateMemories,
        settingsApplied: s.settingsApplied,
        removed: _removedBy(options, current),
      );
    });
  }

  StoreCounts _removedBy(ImportOptions options, StoreCounts current) {
    if (options.mode != ImportMode.replace) return const StoreCounts();
    return StoreCounts(
      conversations: options.conversations ? current.conversations : 0,
      messages: options.conversations ? current.messages : 0,
      memories: options.memories ? current.memories : 0,
    );
  }

  // ----------------------------------------------------------------- apply

  @override
  Future<ImportSummary> apply(
    BackupBundle bundle,
    ImportOptions options, {
    ImportProgressCallback? onProgress,
  }) {
    return _guard(() {
      return _db.transaction<ImportSummary>((Transaction txn) async {
        final bool replace = options.mode == ImportMode.replace;
        final StoreCounts before = await _countsOn(txn);
        final StoreCounts removed = _removedBy(options, before);

        if (replace) {
          onProgress?.call(const ImportProgress('Preparing to replace', 0, 1));
          if (options.conversations) {
            await txn.delete('messages');
            await txn.delete('conversations');
          }
          if (options.memories) await txn.delete('memories');
          if (options.settings && bundle.settings != null) {
            await txn.delete('memory_conversation_flags');
          }
        }

        final _Plan plan =
            await _buildPlan(txn, bundle, options, assumeEmpty: false);
        final ImportSummary s = plan.summary;
        final int total = s.newConversations + s.newMessages + s.newMemories;
        int done = 0;
        void step(String stage, int rows) {
          done += rows;
          onProgress?.call(ImportProgress(stage, done, total));
        }

        // Conversations first (messages point at them).
        await _insertRows(
          txn,
          'conversations',
          <Map<String, Object?>>[
            for (final _NewConversation n in plan.newConversations)
              <String, Object?>{
                'id': n.conversation.id,
                'title': n.conversation.title,
                'created_at': n.conversation.createdAt.millisecondsSinceEpoch,
                'updated_at': n.conversation.updatedAt.millisecondsSinceEpoch,
              },
          ],
          (int n) => step('Saving conversations', n),
        );

        // Messages in file order, so stored order equals backup order.
        final List<Map<String, Object?>> messageRows = <Map<String, Object?>>[
          for (final _NewConversation n in plan.newConversations)
            for (final BackupMessage m in n.messages) _messageRow(m, n.conversation.id),
          for (final _ExistingAdd a in plan.existingAdds)
            for (final BackupMessage m in a.messages) _messageRow(m, a.conversation.id),
        ];
        await _insertRows(
          txn,
          'messages',
          messageRows,
          (int n) => step('Saving messages', n),
        );

        for (final _ExistingAdd a in plan.existingAdds) {
          int latest = a.conversation.updatedAt.millisecondsSinceEpoch;
          for (final BackupMessage m in a.messages) {
            latest = max(latest, m.createdAt.millisecondsSinceEpoch);
          }
          await txn.rawUpdate(
            'UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?',
            <Object?>[latest, a.conversation.id],
          );
        }

        await _insertRows(
          txn,
          'memories',
          <Map<String, Object?>>[
            for (final BackupMemory m in plan.newMemories)
              <String, Object?>{
                'id': m.id,
                'category': m.category,
                'text': m.text,
                'created_at': m.createdAt.millisecondsSinceEpoch,
                'updated_at': m.updatedAt.millisecondsSinceEpoch,
                'source_conversation_id': m.sourceConversationId,
                'status': m.status,
              },
          ],
          (int n) => step('Saving memories', n),
        );

        if (plan.flagsToAdd.isNotEmpty) {
          await _insertRows(
            txn,
            'memory_conversation_flags',
            <Map<String, Object?>>[
              for (final String id in plan.flagsToAdd) <String, Object?>{'conversation_id': id},
            ],
            (int n) {},
            conflict: ConflictAlgorithm.ignore,
          );
        }
        final bool? enabled = plan.memoryEnabled;
        if (enabled != null) {
          await txn.insert(
            'memory_prefs',
            <String, Object?>{'name': _enabledName, 'value': enabled ? '1' : '0'},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        // Verify the result before the transaction commits. A mismatch throws,
        // and the whole import is rolled back.
        final StoreCounts after = await _countsOn(txn);
        final StoreCounts expected = StoreCounts(
          conversations: (replace && options.conversations ? 0 : before.conversations) +
              s.newConversations,
          messages:
              (replace && options.conversations ? 0 : before.messages) + s.newMessages,
          memories: (replace && options.memories ? 0 : before.memories) + s.newMemories,
        );
        if (after != expected) {
          throw const BackupException(
            'The import could not be verified, so it was cancelled. Nothing was changed.',
            BackupErrorCode.storage,
          );
        }
        onProgress?.call(ImportProgress('Finishing', total, total));

        return ImportSummary(
          newConversations: s.newConversations,
          mergedConversations: s.mergedConversations,
          duplicateConversations: s.duplicateConversations,
          newMessages: s.newMessages,
          duplicateMessages: s.duplicateMessages,
          conflictingMessages: s.conflictingMessages,
          newMemories: s.newMemories,
          duplicateMemories: s.duplicateMemories,
          settingsApplied: s.settingsApplied,
          removed: removed,
        );
      });
    });
  }

  Map<String, Object?> _messageRow(BackupMessage m, String conversationId) {
    return <String, Object?>{
      'id': m.id,
      'conversation_id': conversationId,
      'role': m.role,
      'content': m.content,
      'created_at': m.createdAt.millisecondsSinceEpoch,
      'status': m.status,
      'engine': m.engine,
    };
  }

  Future<void> _insertRows(
    Transaction txn,
    String table,
    List<Map<String, Object?>> rows,
    void Function(int rows) onChunk, {
    ConflictAlgorithm? conflict,
  }) async {
    for (int i = 0; i < rows.length; i += _chunk) {
      final int end = min(i + _chunk, rows.length);
      final Batch batch = txn.batch();
      for (int k = i; k < end; k++) {
        batch.insert(table, rows[k], conflictAlgorithm: conflict);
      }
      await batch.commit(noResult: true);
      onChunk(end - i);
    }
  }
}

class _NewConversation {
  const _NewConversation(this.conversation, this.messages);

  final BackupConversation conversation;
  final List<BackupMessage> messages;
}

class _ExistingAdd {
  const _ExistingAdd(this.conversation, this.messages);

  final BackupConversation conversation;
  final List<BackupMessage> messages;
}

class _Plan {
  final List<_NewConversation> newConversations = <_NewConversation>[];
  final List<_ExistingAdd> existingAdds = <_ExistingAdd>[];
  final List<BackupMemory> newMemories = <BackupMemory>[];
  final List<String> flagsToAdd = <String>[];
  bool? memoryEnabled;
  ImportSummary summary = const ImportSummary();
}
