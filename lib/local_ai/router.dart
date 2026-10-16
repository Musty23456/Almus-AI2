import 'registry.dart';
import 'tool.dart';

/// Router decision result
class RouteDecision {
  final String? toolId;
  final bool ambiguous;
  final String? message;

  RouteDecision({this.toolId, this.ambiguous = false, this.message});
}

/// Simple router that decides whether a request can be handled locally.
class LocalRouter {
  final ToolRegistry registry;

  LocalRouter(this.registry);

  /// If the request is a map with explicit `tool` it routes directly.
  /// If the request is a string, performs lightweight intent matching.
  RouteDecision decide(dynamic request) {
    if (request is Map && request['tool'] is String) {
      final String id = request['tool'];
      if (registry.get(id) != null) {
        return RouteDecision(toolId: id);
      } else {
        return RouteDecision(ambiguous: true, message: 'Unknown tool id: $id');
      }
    }

    if (request is String) {
      final String s = request.trim().toLowerCase();
      if (s.startsWith('calc') || s.startsWith('calculate') || s.startsWith('what is') || RegExp(r"^[0-9\-\(]").hasMatch(s)) {
        if (registry.get('calculator') != null) return RouteDecision(toolId: 'calculator');
      }

      if (s.contains('mean') || s.contains('median') || s.contains('standard deviation') || s.contains('variance') || s.contains('mode')) {
        if (registry.get('statistics') != null) return RouteDecision(toolId: 'statistics');
      }
      if (s.contains('convert') || s.contains('to km') || s.contains('to kg') || s.contains('°c') || s.contains('fahrenheit') || s.contains('celsius')) {
        if (registry.get('unit_conversion') != null) return RouteDecision(toolId: 'unit_conversion');
      }
      if (s.contains('date') || s.contains('day') || s.contains('time difference') || s.contains('when is')) {
        if (registry.get('datetime') != null) return RouteDecision(toolId: 'datetime');
      }
      if (s.contains('word count') || s.contains('character count') || s.contains('line count')) {
        if (registry.get('text_tools') != null) return RouteDecision(toolId: 'text_tools');
      }
      return RouteDecision(ambiguous: true, message: 'Could not deterministically route the request.');
    }

    return RouteDecision(ambiguous: true, message: 'Unsupported request type');
  }
}
