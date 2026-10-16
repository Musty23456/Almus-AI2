import 'package:intl/intl.dart';

import '../tool.dart';

class DateTimeInput {
  final String? isoDateA;
  final String? isoDateB;
  final int? addDays;
  DateTimeInput({this.isoDateA, this.isoDateB, this.addDays});
}

class DateTimeOutput {
  final String? addedDateIso;
  final Duration? difference;
  DateTimeOutput({this.addedDateIso, this.difference});
}

class DateTimeTool extends Tool<DateTimeInput, DateTimeOutput> {
  @override
  String get id => 'datetime';

  @override
  String get description => 'Date and time utilities (differences, add/subtract days)';

  @override
  String get inputSchema => 'DateTimeInput { isoDateA?: String, isoDateB?: String, addDays?: int }';

  @override
  void validate(DateTimeInput input) {
    if (input.isoDateA == null && input.isoDateB == null && input.addDays == null) throw ToolError('missing_input', 'At least one input required');
  }

  @override
  Future<ToolResult<DateTimeOutput>> execute(DateTimeInput input) async {
    DateTime? a;
    DateTime? b;
    if (input.isoDateA != null) a = DateTime.parse(input.isoDateA!);
    if (input.isoDateB != null) b = DateTime.parse(input.isoDateB!);
    String? added;
    if (a != null && input.addDays != null) {
      final newDate = a.add(Duration(days: input.addDays!));
      added = newDate.toIso8601String();
    }
    Duration? diff;
    if (a != null && b != null) diff = a.difference(b).abs();
    return ToolResult(result: DateTimeOutput(addedDateIso: added, difference: diff));
  }
}
