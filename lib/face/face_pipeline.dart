import 'dart:typed_data';

import 'face_model_manifest.dart';
import 'face_models.dart';
import 'face_ports.dart';
import 'face_preprocess.dart';

enum PipelineFailure { decodeFailed, alignFailed, embedFailed, modelMismatch }

class PipelineResult {
  const PipelineResult._({this.embedding, this.problem, this.failure});

  const PipelineResult.success(FaceEmbedding e) : this._(embedding: e);
  const PipelineResult.quality(FaceQualityProblem p) : this._(problem: p);
  const PipelineResult.failed(PipelineFailure f) : this._(failure: f);

  final FaceEmbedding? embedding;
  final FaceQualityProblem? problem;
  final PipelineFailure? failure;

  bool get ok => embedding != null;
}

/// Picture -> detect -> quality gate -> align -> embed.
/// The captured picture is always deleted when processing ends.
class FacePipeline {
  FacePipeline({
    required this.manifest,
    required this.decoder,
    required this.detector,
    required this.embedder,
    this.gate = const FaceQualityGate(),
  });

  final FaceModelManifest manifest;
  final FaceImageDecoder decoder;
  final FaceDetectorPort detector;
  final FaceEmbedder embedder;
  final FaceQualityGate gate;

  /// [onFaceDetected] runs once a single usable face has been found, before
  /// any embedding is computed.
  Future<PipelineResult> process(
    CapturedFrame frame, {
    void Function()? onFaceDetected,
  }) async {
    try {
      final RgbImage? image = await decoder.decode(frame);
      if (image == null) {
        return const PipelineResult.failed(PipelineFailure.decodeFailed);
      }
      final List<DetectedFace> faces =
          await detector.detect(frame, image.width, image.height);
      final FaceQualityProblem? problem = gate.check(faces);
      if (problem != null) return PipelineResult.quality(problem);
      final DetectedFace face = faces.first;
      final RgbImage? aligned =
          alignFace(image, face.leftEye!, face.rightEye!, manifest);
      if (aligned == null) {
        return const PipelineResult.failed(PipelineFailure.alignFailed);
      }
      final FaceQualityProblem? light =
          gate.checkBrightness(meanLuma(aligned));
      if (light != null) return PipelineResult.quality(light);

      onFaceDetected?.call();

      final Float32List raw;
      try {
        raw = await embedder.embed(toTensor(aligned, manifest));
      } on Object {
        return const PipelineResult.failed(PipelineFailure.embedFailed);
      }
      if (raw.length != manifest.embeddingDimension) {
        return const PipelineResult.failed(PipelineFailure.modelMismatch);
      }
      try {
        return PipelineResult.success(
          FaceEmbedding.fromRaw(raw, manifest.modelId),
        );
      } on ArgumentError {
        return const PipelineResult.failed(PipelineFailure.embedFailed);
      }
    } finally {
      await frame.discard();
    }
  }
}
