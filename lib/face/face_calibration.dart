/// Helpers to choose a threshold from MEASURED scores.
///
/// "Genuine" scores compare two different photos of the same person.
/// "Impostor" scores compare photos of different people. Both lists must come
/// from a labelled evaluation set made with the same model and the same
/// preprocessing as the app. Nothing here invents numbers: with too little
/// data the functions return `sufficient == false` and no threshold.
class CalibrationResult {
  const CalibrationResult({
    required this.sufficient,
    required this.genuineCount,
    required this.impostorCount,
    required this.targetFar,
    this.threshold,
    this.achievedFar,
    this.frr,
    this.problem,
  });

  final bool sufficient;
  final int genuineCount;
  final int impostorCount;
  final double targetFar;
  final double? threshold;

  /// Measured false-accept rate at [threshold] on the supplied data.
  final double? achievedFar;

  /// Measured false-reject rate at [threshold] on the supplied data.
  final double? frr;
  final String? problem;
}

const int kMinGenuinePairs = 100;

/// Rate of [impostor] scores accepted at [threshold] (score >= threshold).
double falseAcceptRate(List<double> impostor, double threshold) {
  if (impostor.isEmpty) return double.nan;
  final int n = impostor.where((double s) => s >= threshold).length;
  return n / impostor.length;
}

/// Rate of [genuine] scores rejected at [threshold] (score < threshold).
double falseRejectRate(List<double> genuine, double threshold) {
  if (genuine.isEmpty) return double.nan;
  final int n = genuine.where((double s) => s < threshold).length;
  return n / genuine.length;
}

/// Smallest threshold whose measured FAR on [impostor] is <= [targetFar].
CalibrationResult chooseThreshold({
  required List<double> genuine,
  required List<double> impostor,
  required double targetFar,
}) {
  CalibrationResult fail(String why) => CalibrationResult(
        sufficient: false,
        genuineCount: genuine.length,
        impostorCount: impostor.length,
        targetFar: targetFar,
        problem: why,
      );
  if (!(targetFar > 0 && targetFar < 1)) {
    return fail('The target false-accept rate must be between 0 and 1.');
  }
  if (genuine.any((double s) => s.isNaN) ||
      impostor.any((double s) => s.isNaN)) {
    return fail('Scores contain invalid values.');
  }
  if (genuine.length < kMinGenuinePairs) {
    return fail('Need at least $kMinGenuinePairs genuine pairs.');
  }
  final int neededImpostor = (10 / targetFar).ceil();
  if (impostor.length < neededImpostor) {
    return fail(
      'Need at least $neededImpostor impostor pairs to measure a false-accept '
      'rate of $targetFar.',
    );
  }
  final List<double> sorted = List<double>.of(impostor)..sort();
  // Allowed number of accepted impostors.
  final int allowed = (targetFar * sorted.length).floor();
  // Threshold just above the (allowed+1)-th highest impostor score.
  final int idx = sorted.length - 1 - allowed;
  final double threshold = sorted[idx] + 1e-6;
  return CalibrationResult(
    sufficient: true,
    genuineCount: genuine.length,
    impostorCount: impostor.length,
    targetFar: targetFar,
    threshold: threshold,
    achievedFar: falseAcceptRate(impostor, threshold),
    frr: falseRejectRate(genuine, threshold),
  );
}
