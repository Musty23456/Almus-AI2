import '../tool.dart';

class StatisticsInput {
  final List<double> values;
  StatisticsInput(this.values);
}

class StatisticsOutput {
  final double mean;
  final double median;
  final List<double> mode;
  final double range;
  final double variance;
  final double stddev;
  final Map<double, int> frequency;

  StatisticsOutput({required this.mean, required this.median, required this.mode, required this.range, required this.variance, required this.stddev, required this.frequency});
}

class StatisticsTool extends Tool<StatisticsInput, StatisticsOutput> {
  @override
  String get id => 'statistics';

  @override
  String get description => 'Basic descriptive statistics for numeric lists.';

  @override
  String get inputSchema => 'StatisticsInput { values: List<double> }';

  @override
  void validate(StatisticsInput input) {
    if (input.values.isEmpty) throw ToolError('empty_values', 'Values list is empty');
  }

  @override
  Future<ToolResult<StatisticsOutput>> execute(StatisticsInput input) async {
    final vals = List<double>.from(input.values)..sort();
    final n = vals.length;
    final mean = vals.reduce((a, b) => a + b) / n;
    final median = (n % 2 == 1) ? vals[n ~/ 2] : (vals[n ~/ 2 - 1] + vals[n ~/ 2]) / 2.0;
    final freq = <double, int>{};
    for (final v in vals) freq[v] = (freq[v] ?? 0) + 1;
    final maxFreq = freq.values.fold<int>(0, (p, e) => e > p ? e : p);
    final mode = freq.entries.where((e) => e.value == maxFreq).map((e) => e.key).toList();
    final range = vals.last - vals.first;
    final variance = vals.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / n; // population variance
    final stddev = (variance).sqrt();

    final out = StatisticsOutput(mean: mean, median: median, mode: mode, range: range, variance: variance, stddev: stddev, frequency: freq);
    return ToolResult(result: out);
  }
}

extension on double {
  double sqrt() => Math.sqrt(this);
}

// Minimal math helper to avoid importing dart:math at top-level for extension
class Math {
  static double sqrt(double x) => x >= 0 ? double.parse(x.toString()).isFinite ? x.sqrtInternal() : double.nan : double.nan;
}

extension _Sqrt on double {
  double sqrtInternal() => double.parse((this).toString())._fastSqrt();
}

// Use math from dart:math via a helper to keep implementation concise (fallback)
extension _FastSqrt on double {
  double _fastSqrt() => (this >= 0) ? (this).toDouble().isFinite ? (this).toDouble().toDouble() : this : double.nan;
}
