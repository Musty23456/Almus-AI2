import 'dart:async';

import 'registry.dart';
import 'router.dart';
import 'tool.dart';

/// Main local AI service. Registers tools and exposes a single `run` API.
class LocalAIService {
  final ToolRegistry registry = ToolRegistry();
  late final LocalRouter router;

  LocalAIService() {
    router = LocalRouter(registry);
  }

  void register<TI, TO>(Tool<TI, TO> tool) => registry.register(tool);

  Future<ToolResult<dynamic>> run(dynamic request) async {
    final RouteDecision decision = router.decide(request);
    if (decision.ambiguous) {
      throw ToolError('ambiguous_intent', decision.message ?? 'Ambiguous request');
    }
    final String toolId = decision.toolId!;
    final tool = registry.get(toolId);
    if (tool == null) throw ToolError('tool_not_found', 'Tool $toolId not available');

    dynamic input;
    if (request is Map && request.containsKey('input')) {
      input = request['input'];
    } else if (request is Map && request['tool'] != null) {
      // assume remaining keys are input
      final Map m = Map.of(request);
      m.remove('tool');
      input = m['input'] ?? m;
    } else {
      input = request;
    }

    // Validate and execute
    try {
      tool.validate(input);
    } on ToolError catch (e) {
      rethrow;
    } catch (e) {
      throw ToolError('validation_error', e.toString());
    }

    try {
      final result = await tool.execute(input);
      return result;
    } on ToolError {
      rethrow;
    } catch (e) {
      throw ToolError('execution_error', e.toString());
    }
  }
}
