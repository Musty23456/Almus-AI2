import 'dart:convert';

import 'face_models.dart';

/// Describes ONE recognition model and how to use it. The app refuses to
/// match faces unless a manifest is present, valid and CALIBRATED. Nothing in
/// the app ships a model or a threshold of its own.
class FaceModelManifest {
  const FaceModelManifest({
    required this.modelId,
    required this.sha256,
    required this.license,
    required this.licenseUrl,
    required this.trainingDataNote,
    required this.inputSize,
    required this.embeddingDimension,
    required this.inputMean,
    required this.inputStd,
    required this.eyeLeft,
    required this.eyeRight,
    required this.calibration,
  });

  final String modelId;

  /// Lowercase hex SHA-256 of the model file; a different file is refused.
  final String sha256;
  final String license;
  final String licenseUrl;

  /// Where the training data came from and under what terms (free text).
  final String trainingDataNote;

  /// Square input side in pixels (for example 112).
  final int inputSize;
  final int embeddingDimension;

  /// Per-channel normalisation: (pixel - mean) / std.
  final double inputMean;
  final double inputStd;

  /// Where the eye centres must land in the aligned input (pixels).
  final FacePoint eyeLeft;
  final FacePoint eyeRight;

  /// Null means the model has NOT been calibrated and cannot be used.
  final ThresholdCalibration? calibration;

  bool get isCalibrated => calibration != null;

  static FaceModelManifest? tryParse(String jsonText) {
    try {
      final Object? decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, Object?>) return null;
      String s(String k) {
        final Object? v = decoded[k];
        if (v is! String || v.trim().isEmpty) throw const FormatException();
        return v;
      }

      int i(String k) {
        final Object? v = decoded[k];
        if (v is! int || v <= 0) throw const FormatException();
        return v;
      }

      double d(Object? v) {
        if (v is! num || !v.isFinite) throw const FormatException();
        return v.toDouble();
      }

      final Object? eyes = decoded['eyes'];
      if (eyes is! Map<String, Object?>) return null;
      final Object? l = eyes['left'];
      final Object? r = eyes['right'];
      if (l is! List<Object?> || r is! List<Object?>) return null;
      if (l.length != 2 || r.length != 2) return null;

      ThresholdCalibration? cal;
      final Object? c = decoded['calibration'];
      if (c is Map<String, Object?>) {
        cal = ThresholdCalibration.tryFromJson(c);
      }
      final String sha = s('sha256').toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
      return FaceModelManifest(
        modelId: s('model_id'),
        sha256: sha,
        license: s('license'),
        licenseUrl: s('license_url'),
        trainingDataNote: s('training_data_note'),
        inputSize: i('input_size'),
        embeddingDimension: i('embedding_dimension'),
        inputMean: d(decoded['input_mean']),
        inputStd: d(decoded['input_std']) == 0 ? 1.0 : d(decoded['input_std']),
        eyeLeft: FacePoint(d(l[0]), d(l[1])),
        eyeRight: FacePoint(d(r[0]), d(r[1])),
        calibration: cal,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// A threshold that was MEASURED on labelled score data (see
/// tool/calibrate_threshold.py). The counts are kept so a reader can see how
/// little or how much evidence is behind the number.
class ThresholdCalibration {
  const ThresholdCalibration({
    required this.threshold,
    required this.margin,
    required this.genuinePairs,
    required this.impostorPairs,
    required this.targetFar,
    required this.dataDescription,
  });

  /// Minimum cosine similarity to accept.
  final double threshold;

  /// Best identity must beat the runner-up by at least this much.
  final double margin;
  final int genuinePairs;
  final int impostorPairs;

  /// The false-accept rate the threshold was chosen for (for example 0.001).
  final double targetFar;

  /// Free-text description of the evaluation data.
  final String dataDescription;

  /// Smallest evidence the app accepts: with fewer impostor pairs than
  /// 1/targetFar x 10, a false-accept rate cannot be estimated.
  bool get hasEnoughEvidence =>
      genuinePairs >= 100 &&
      impostorPairs >= (10 / targetFar).ceil() &&
      targetFar > 0 &&
      targetFar < 1;

  static ThresholdCalibration? tryFromJson(Map<String, Object?> j) {
    final Object? t = j['threshold'];
    final Object? m = j['margin'];
    final Object? g = j['genuine_pairs'];
    final Object? imp = j['impostor_pairs'];
    final Object? far = j['target_far'];
    final Object? desc = j['data_description'];
    if (t is! num || m is! num || g is! int || imp is! int || far is! num) {
      return null;
    }
    if (desc is! String || desc.trim().isEmpty) return null;
    if (!t.isFinite || !m.isFinite || t <= -1 || t >= 1 || m < 0) return null;
    final ThresholdCalibration c = ThresholdCalibration(
      threshold: t.toDouble(),
      margin: m.toDouble(),
      genuinePairs: g,
      impostorPairs: imp,
      targetFar: far.toDouble(),
      dataDescription: desc,
    );
    return c.hasEnoughEvidence ? c : null;
  }
}
