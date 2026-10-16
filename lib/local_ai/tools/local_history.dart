import '../../data/app_database.dart';
import '../tool.dart';

class LocalHistoryInput {
  final String? query; // simple substring match
  final int? sinceMillis; // filter by updated_at >= sinceMillis
  LocalHistoryInput({this.query, this.sinceMillis});
}

class LocalHistoryOutput {
  final List<Map<String, dynamic>> conversations;
  LocalHistoryOutput(this.conversations);
}

class LocalHistoryTool extends Tool<LocalHistoryInput, LocalHistoryOutput> {
  final AppDatabase dbOwner;
  LocalHistoryTool(this.dbOwner);

  @override
  String get id => 'local_history';

  @override
  String get description => 'Search and open local conversations.';

  @override
  String get inputSchema => 'LocalHistoryInput { query?: String, sinceMillis?: int }';

  @override
  void validate(LocalHistoryInput input) {}

  @override
  Future<ToolResult<LocalHistoryOutput>> execute(LocalHistoryInput input) async {
    final where = <String>[];
    final args = <dynamic>[];
    if (input.query != null && input.query!.trim().isNotEmpty) {
      where.add('(title LIKE ? OR id IN (SELECT conversation_id FROM messages WHERE content LIKE ?))');
      final q = '%${input.query}%';
      args..add(q)..add(q);
    }
    if (input.sinceMillis != null) {
      where.add('updated_at >= ?');
      args.add(input.sinceMillis);
    }
    final whereClause = where.isEmpty ? null : where.join(' AND ');
    final rows = await dbOwner.db.query('conversations', where: whereClause, whereArgs: args.isEmpty ? null : args, orderBy: 'updated_at DESC');
    return ToolResult(result: LocalHistoryOutput(rows));
  }
}
