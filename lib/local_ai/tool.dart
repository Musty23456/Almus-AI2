// Tool interface and common types for local tools

import 'package:meta/meta.dart';

/// Result source flag
enum ResultSource { local, ai, external, cached }

class ToolError implements Exception {
  final String code;
  final String message;
  ToolError(this.code, this.message);
  @override
  String toString() => 'ToolError($code): $message';
}

/// Generic execution result from a tool
class ToolResult<T> {
  final T result;
  final ResultSource source;
  final Map<String, dynamic>? metadata;

  ToolResult({required this.result, this.source = ResultSource.local, this.metadata});
}

/// Tool definition contract
abstract class Tool<I, O> {
  String get id;
  String get description;

  /// Input schema description (human-readable)
  String get inputSchema;

  /// Validate inputs and throw ToolError on invalid input
  void validate(I input);

  /// Execute the tool. May throw ToolError.
  Future<ToolResult<O>> execute(I input);

  /// Permission requirements (for future use)
  List<String> get requiredPermissions => const [];
}
