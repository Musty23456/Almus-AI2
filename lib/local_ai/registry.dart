import 'tool.dart';

/// Simple registry that holds tool instances and dispatches by id.
class ToolRegistry {
  final Map<String, Tool<dynamic, dynamic>> _tools = {};

  void register<TI, TO>(Tool<TI, TO> tool) {
    _tools[tool.id] = tool as Tool<dynamic, dynamic>;
  }

  Tool<dynamic, dynamic>? get(String id) => _tools[id];

  List<String> get toolIds => _tools.keys.toList(growable: false);
}
