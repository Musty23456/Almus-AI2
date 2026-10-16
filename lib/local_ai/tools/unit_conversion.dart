import '../tool.dart';

class UnitConversionInput {
  final double value;
  final String from;
  final String to;
  UnitConversionInput({required this.value, required this.from, required this.to});
}

class UnitConversionOutput {
  final double value;
  final String from;
  final String to;
  UnitConversionOutput(this.value, this.from, this.to);
}

class UnitConversionTool extends Tool<UnitConversionInput, UnitConversionOutput> {
  @override
  String get id => 'unit_conversion';

  @override
  String get description => 'Common unit conversions (length, mass, temperature, time).';

  @override
  String get inputSchema => 'UnitConversionInput { value: double, from: String, to: String }';

  final Map<String, double> _length = {
    'm': 1.0,
    'km': 1000.0,
    'cm': 0.01,
    'mm': 0.001,
    'mi': 1609.344,
    'yd': 0.9144,
    'ft': 0.3048,
    'in': 0.0254,
  };
  final Map<String, double> _mass = {
    'kg': 1.0,
    'g': 0.001,
    'mg': 0.000001,
    'lb': 0.45359237,
    'oz': 0.0283495231,
  };
  final Map<String, double> _time = {
    's': 1.0,
    'min': 60.0,
    'h': 3600.0,
    'd': 86400.0,
  };

  @override
  void validate(UnitConversionInput input) {
    if (input.from.isEmpty || input.to.isEmpty) throw ToolError('missing_unit', 'from/to units required');
  }

  @override
  Future<ToolResult<UnitConversionOutput>> execute(UnitConversionInput input) async {
    final from = input.from.toLowerCase();
    final to = input.to.toLowerCase();
    // Temperature special-cases
    if (from == to) return ToolResult(result: UnitConversionOutput(input.value, from, to));
    if (_isTemp(from) || _isTemp(to)) {
      final val = _convertTemp(input.value, from, to);
      return ToolResult(result: UnitConversionOutput(val, from, to));
    }
    if (_length.containsKey(from) && _length.containsKey(to)) {
      final base = input.value * _length[from]!;
      final out = base / _length[to]!;
      return ToolResult(result: UnitConversionOutput(out, from, to));
    }
    if (_mass.containsKey(from) && _mass.containsKey(to)) {
      final base = input.value * _mass[from]!;
      final out = base / _mass[to]!;
      return ToolResult(result: UnitConversionOutput(out, from, to));
    }
    if (_time.containsKey(from) && _time.containsKey(to)) {
      final base = input.value * _time[from]!;
      final out = base / _time[to]!;
      return ToolResult(result: UnitConversionOutput(out, from, to));
    }
    throw ToolError('unsupported_conversion', 'Conversion from $from to $to not supported');
  }

  bool _isTemp(String u) => ['c', '°c', 'celsius', 'f', '°f', 'fahrenheit', 'k', 'kelvin'].contains(u);

  double _convertTemp(double v, String from, String to) {
    double c;
    switch (from) {
      case 'c':
      case '°c':
      case 'celsius':
        c = v;
        break;
      case 'f':
      case '°f':
      case 'fahrenheit':
        c = (v - 32) * 5 / 9;
        break;
      case 'k':
      case 'kelvin':
        c = v - 273.15;
        break;
      default:
        throw ToolError('unsupported_unit', from);
    }
    switch (to) {
      case 'c':
      case '°c':
      case 'celsius':
        return c;
      case 'f':
      case '°f':
      case 'fahrenheit':
        return c * 9 / 5 + 32;
      case 'k':
      case 'kelvin':
        return c + 273.15;
      default:
        throw ToolError('unsupported_unit', to);
    }
  }
}
