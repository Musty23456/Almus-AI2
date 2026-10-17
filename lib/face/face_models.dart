import 'dart:math' as math;
import 'dart:typed_data';

/// A point in image pixels.
class FacePoint {
  const FacePoint(this.x, this.y);
  final double x;
  final double y;
}

/// What a face DETECTOR reports. This says where a face is, never who it is.
class DetectedFace {
  const DetectedFace({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.imageWidth,
    required this.imageHeight,
    this.leftEye,
    this.rightEye,
    this.yaw,
    this.pitch,
    this.roll,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final int imageWidth;
  final int imageHeight;

  /// Eye centres in image pixels, ordered by position: [leftEye] is the one
  /// with the smaller x coordinate (the left side of the picture).
  final FacePoint? leftEye;
  final FacePoint? rightEye;

  /// Head angles in degrees, when the detector reports them.
  final double? yaw;
  final double? pitch;
  final double? roll;

  double get right => left + width;
  double get bottom => top + height;
}

/// Why a captured face was not good enough to use.
enum FaceQualityProblem {
  noFace,
  multipleFaces,
  tooSmall,
  partlyOutsideImage,
  eyesNotFound,
  headTurned,
  tooDark,
  tooBright,
}

/// Rules a detected face must pass before it is embedded or enrolled.
class FaceQualityGate {
  const FaceQualityGate({
    this.minFaceFraction = 0.25,
    this.maxYawDegrees = 20,
    this.maxPitchDegrees = 20,
    this.maxRollDegrees = 25,
    this.minMeanLuma = 55,
    this.maxMeanLuma = 205,
  });

  /// Smallest allowed face width as a fraction of the image width.
  final double minFaceFraction;
  final double maxYawDegrees;
  final double maxPitchDegrees;
  final double maxRollDegrees;

  /// Mean brightness (0-255) of the aligned face crop.
  final double minMeanLuma;
  final double maxMeanLuma;

  /// Returns the first problem found with [faces], or null when exactly one
  /// usable face is present. Brightness is checked later, on the aligned crop.
  FaceQualityProblem? check(List<DetectedFace> faces) {
    if (faces.isEmpty) return FaceQualityProblem.noFace;
    if (faces.length > 1) return FaceQualityProblem.multipleFaces;
    final DetectedFace f = faces.first;
    if (f.imageWidth <= 0 || f.imageHeight <= 0) {
      return FaceQualityProblem.noFace;
    }
    if (f.width / f.imageWidth < minFaceFraction) {
      return FaceQualityProblem.tooSmall;
    }
    if (f.left < 0 || f.top < 0 || f.right > f.imageWidth ||
        f.bottom > f.imageHeight) {
      return FaceQualityProblem.partlyOutsideImage;
    }
    if (f.leftEye == null || f.rightEye == null) {
      return FaceQualityProblem.eyesNotFound;
    }
    if ((f.yaw != null && f.yaw!.abs() > maxYawDegrees) ||
        (f.pitch != null && f.pitch!.abs() > maxPitchDegrees) ||
        (f.roll != null && f.roll!.abs() > maxRollDegrees)) {
      return FaceQualityProblem.headTurned;
    }
    return null;
  }

  FaceQualityProblem? checkBrightness(double meanLuma) {
    if (meanLuma < minMeanLuma) return FaceQualityProblem.tooDark;
    if (meanLuma > maxMeanLuma) return FaceQualityProblem.tooBright;
    return null;
  }
}

String describeQualityProblem(FaceQualityProblem p) {
  switch (p) {
    case FaceQualityProblem.noFace:
      return 'No face found. Face the camera in good light.';
    case FaceQualityProblem.multipleFaces:
      return 'More than one face found. Only one person should be in view.';
    case FaceQualityProblem.tooSmall:
      return 'Move closer to the camera.';
    case FaceQualityProblem.partlyOutsideImage:
      return 'Keep your whole face inside the picture.';
    case FaceQualityProblem.eyesNotFound:
      return 'Both eyes must be visible.';
    case FaceQualityProblem.headTurned:
      return 'Look straight at the camera.';
    case FaceQualityProblem.tooDark:
      return 'Too dark. Move to better light.';
    case FaceQualityProblem.tooBright:
      return 'Too bright. Avoid strong light directly on your face.';
  }
}

/// A face embedding: a unit-length vector produced by a recognition model.
/// It is biometric data. It is never logged, printed or uploaded.
class FaceEmbedding {
  FaceEmbedding._(this.values, this.modelId);

  /// Normalises [raw] to unit length. Throws [ArgumentError] for an empty,
  /// non-finite or all-zero vector, so a broken model can never produce a
  /// "valid" embedding.
  factory FaceEmbedding.fromRaw(Float32List raw, String modelId) {
    if (raw.isEmpty) throw ArgumentError('Empty embedding.');
    double sum = 0;
    for (final double v in raw) {
      if (v.isNaN || v.isInfinite) throw ArgumentError('Invalid embedding.');
      sum += v * v;
    }
    if (sum <= 1e-12) throw ArgumentError('Degenerate embedding.');
    final double norm = math.sqrt(sum);
    final Float32List out = Float32List(raw.length);
    for (int i = 0; i < raw.length; i++) {
      out[i] = raw[i] / norm;
    }
    return FaceEmbedding._(out, modelId);
  }

  /// Restores an already-normalised embedding (for example from the vault).
  factory FaceEmbedding.fromStored(Float32List stored, String modelId) =>
      FaceEmbedding.fromRaw(stored, modelId);

  final Float32List values;
  final String modelId;

  int get dimension => values.length;

  /// Cosine similarity with [other] (both are unit length, so a dot product).
  double similarity(FaceEmbedding other) {
    if (other.dimension != dimension || other.modelId != modelId) {
      throw ArgumentError('Embeddings come from different models.');
    }
    double s = 0;
    for (int i = 0; i < values.length; i++) {
      s += values[i] * other.values[i];
    }
    return s;
  }

  @override
  String toString() => 'FaceEmbedding(<hidden>)';
}
