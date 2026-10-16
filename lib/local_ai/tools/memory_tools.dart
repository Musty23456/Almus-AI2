import '../../data/app_database.dart';
import '../tool.dart';

class MemoryToolsInput {
  final String? query;
  final String? id;
  final Map<String, dynamic>? edit; // fields to update
  final bool allowEdit;
  MemoryToolsInput({this.query, this.id, this.edit, this.allowEdit = false});
}

class MemoryToolsOutput {
  final List<Map<String, dynamic>> memories;
  MemoryToolsOutput(this.memories);
}

class MemoryTools extends Tool<MemoryToolsInput, MemoryToolsOutput> {
  final AppDatabase dbOwner;
  MemoryTools(this.dbOwner);

  @override
  String get id => 'memory_tools';

  @override
  String get description => 'Search, view, edit and delete personal memory records. Edits/deletes require allowEdit=true.';

  @override
  String get inputSchema => 'MemoryToolsInput { query?: String, id?: String, edit?: {...}, allowEdit?: bool }';

  @override
  void validate(MemoryToolsInput input) {
    if (input.query == null && input.id == null && input.edit == null) throw ToolError('missing_input', 'Provide query or id or edit');
  }

  @override
  Future<ToolResult<MemoryToolsOutput>> execute(MemoryToolsInput input) async {
    if (input.edit != null) {
      if (!input.allowEdit) throw ToolError('permission_denied', 'Editing memories requires explicit allowEdit=true');
      final id = input.edit!['id'] as String?;
      if (id == null) throw ToolError('missing_id', 'edit requires id');
      final updates = <String, dynamic>{};
      if (input.edit!.containsKey('text')) updates['text'] = input.edit!['text'];
      if (input.edit!.containsKey('status')) updates['status'] = input.edit!['status'];
      if (updates.isEmpty) throw ToolError('nothing_to_edit', 'No editable fields provided');
      final sets = updates.keys.map((k) => '$k = ?').join(', ');
      final args = updates.values.toList()..add(id);
      await dbOwner.db.rawUpdate('UPDATE memories SET $sets WHERE id = ?', args);
    }
    if (input.id != null && input.query == null && input.edit == null) {
      final rows = await dbOwner.db.query('memories', where: 'id = ?', whereArgs: [input.id]);
      return ToolResult(result: MemoryToolsOutput(rows));
    }
    final where = <String>[];
    final args = <dynamic>[];
    if (input.query != null) {
      where.add('text LIKE ?');
      args.add('%${input.query}%');
    }
    final whereClause = where.isEmpty ? null : where.join(' AND ');
    final rows = await dbOwner.db.query('memories', where: whereClause, whereArgs: args.isEmpty ? null : args, orderBy: 'updated_at DESC');
    return ToolResult(result: MemoryToolsOutput(rows));
  }
}
