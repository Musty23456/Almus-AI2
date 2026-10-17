import 'face_model_manifest.dart';
import 'face_models.dart';

/// One enrolled person: a label chosen by the user plus a few embeddings.
class EnrolledIdentity {
  const EnrolledIdentity({
    required this.id,
    required this.displayName,
    required this.createdAt,
    required this.samples,
  });

  final String id;
  final String displayName;
  final DateTime createdAt;
  final List<FaceEmbedding> samples;
}

enum MatchKind {
  /// The best identity passed the calibrated threshold and margin.
  match,

  /// A usable embedding was compared and nobody passed: an unknown person.
  unknown,

  /// The comparison could not be made (no calibration, no enrollment, model
  /// mismatch). This is NOT the same as "unknown person".
  cannotCompare,
}

class MatchOutcome {
  const MatchOutcome._(this.kind, this.identityId, this.score, this.reason);

  const MatchOutcome.match(String identityId, double score)
      : this._(MatchKind.match, identityId, score, null);
  const MatchOutcome.unknown(double? bestScore)
      : this._(MatchKind.unknown, null, bestScore, null);
  const MatchOutcome.cannotCompare(String reason)
      : this._(MatchKind.cannotCompare, null, null, reason);

  final MatchKind kind;
  final String? identityId;

  /// Best cosine similarity seen. For the UI and tests only; never logged.
  final double? score;
  final String? reason;
}

/// Compares a probe embedding with enrolled identities.
///
/// Rules (all of them must hold to report a match):
///  1. the model has a valid, calibrated threshold (never a built-in default);
///  2. the probe and every enrolled sample come from the same model;
///  3. the best identity's best-sample similarity is >= threshold;
///  4. when several identities are enrolled, the best beats the runner-up by
///     at least the calibrated margin.
/// Anything else is "unknown" or "cannot compare". There is no "closest
/// match" fallback.
class FaceMatcher {
  const FaceMatcher(this.manifest);

  final FaceModelManifest manifest;

  MatchOutcome match(
    FaceEmbedding probe,
    List<EnrolledIdentity> identities,
  ) {
    final ThresholdCalibration? cal = manifest.calibration;
    if (cal == null || !cal.hasEnoughEvidence) {
      return const MatchOutcome.cannotCompare(
        'The model has no calibrated threshold.',
      );
    }
    if (probe.modelId != manifest.modelId ||
        probe.dimension != manifest.embeddingDimension) {
      return const MatchOutcome.cannotCompare(
        'The embedding does not belong to the installed model.',
      );
    }
    final List<EnrolledIdentity> usable = identities
        .where((EnrolledIdentity e) => e.samples.isNotEmpty)
        .toList();
    if (usable.isEmpty) {
      return const MatchOutcome.cannotCompare('Nobody is enrolled.');
    }
    double best = -2;
    String? bestId;
    double second = -2;
    for (final EnrolledIdentity id in usable) {
      double idBest = -2;
      for (final FaceEmbedding s in id.samples) {
        if (s.modelId != probe.modelId || s.dimension != probe.dimension) {
          return const MatchOutcome.cannotCompare(
            'Enrolled data was made with a different model. Enrol again.',
          );
        }
        final double sim = probe.similarity(s);
        if (sim > idBest) idBest = sim;
      }
      if (idBest > best) {
        second = best;
        best = idBest;
        bestId = id.id;
      } else if (idBest > second) {
        second = idBest;
      }
    }
    if (bestId == null || best < cal.threshold) {
      return MatchOutcome.unknown(best < -1.5 ? null : best);
    }
    if (usable.length > 1 && best - second < cal.margin) {
      return MatchOutcome.unknown(best);
    }
    return MatchOutcome.match(bestId, best);
  }
}
