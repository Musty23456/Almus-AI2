import 'dart:typed_data';

import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

FacePipeline makePipeline(Rig rig) => FacePipeline(
      manifest: rig.manifest,
      decoder: rig.decoder,
      detector: rig.detector,
      embedder: rig.embedder,
    );

void main() {
  test('good picture gives a unit-length embedding and the picture is deleted',
      () async {
    final Rig rig = Rig(embeddings: <Float32List>[vec(3, 4, 0, 0)]);
    bool detected = false;
    final PipelineResult r = await makePipeline(rig).process(
      FakeFrame(rig.capture),
      onFaceDetected: () => detected = true,
    );
    expect(r.ok, isTrue);
    expect(detected, isTrue);
    expect(r.embedding!.similarity(r.embedding!), closeTo(1.0, 1e-6));
    expect(rig.capture.discarded, 1);
  });

  test('no face: quality problem, embedder never called, picture deleted',
      () async {
    final Rig rig = Rig();
    rig.detector.script = <List<DetectedFace>>[<DetectedFace>[]];
    final PipelineResult r =
        await makePipeline(rig).process(FakeFrame(rig.capture));
    expect(r.problem, FaceQualityProblem.noFace);
    expect(rig.embedder.calls, 0);
    expect(rig.capture.discarded, 1);
  });

  test('too dark: rejected before any embedding is made', () async {
    final Rig rig = Rig();
    final FacePipeline p = FacePipeline(
      manifest: rig.manifest,
      decoder: FakeDecoder(luma: 10),
      detector: rig.detector,
      embedder: rig.embedder,
    );
    final PipelineResult r = await p.process(FakeFrame(rig.capture));
    expect(r.problem, FaceQualityProblem.tooDark);
    expect(rig.embedder.calls, 0);
  });

  test('unreadable picture fails cleanly', () async {
    final Rig rig = Rig();
    rig.decoder.fail = true;
    final PipelineResult r =
        await makePipeline(rig).process(FakeFrame(rig.capture));
    expect(r.failure, PipelineFailure.decodeFailed);
    expect(rig.capture.discarded, 1);
  });

  test('a model that returns the wrong size is rejected', () async {
    final Rig rig =
        Rig(embeddings: <Float32List>[Float32List.fromList(<double>[1, 2])]);
    final PipelineResult r =
        await makePipeline(rig).process(FakeFrame(rig.capture));
    expect(r.failure, PipelineFailure.modelMismatch);
  });

  test('a model that returns zeros or NaN is rejected', () async {
    final Rig zeros = Rig(embeddings: <Float32List>[vec(0, 0, 0, 0)]);
    expect((await makePipeline(zeros).process(FakeFrame(zeros.capture))).failure,
        PipelineFailure.embedFailed);
    final Rig nan = Rig(embeddings: <Float32List>[vec(double.nan, 1, 0, 0)]);
    expect((await makePipeline(nan).process(FakeFrame(nan.capture))).failure,
        PipelineFailure.embedFailed);
  });
}
