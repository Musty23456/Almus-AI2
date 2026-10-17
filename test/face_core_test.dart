import 'dart:typed_data';

import 'package:almus_ai/face/face_calibration.dart';
import 'package:almus_ai/face/face_matcher.dart';
import 'package:almus_ai/face/face_model_manifest.dart';
import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_preprocess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

EnrolledIdentity person(String id, List<Float32List> vs) => EnrolledIdentity(
      id: id,
      displayName: 'Name $id',
      createdAt: DateTime.utc(2026, 1, 1),
      samples: <FaceEmbedding>[for (final Float32List v in vs) emb(v)],
    );

void main() {
  group('FaceEmbedding', () {
    test('is normalised to unit length', () {
      final FaceEmbedding e = emb(vec(3, 4, 0, 0));
      expect(e.values[0], closeTo(0.6, 1e-6));
      expect(e.values[1], closeTo(0.8, 1e-6));
      expect(e.similarity(e), closeTo(1.0, 1e-6));
    });

    test('rejects empty, zero and non-finite vectors', () {
      expect(() => FaceEmbedding.fromRaw(Float32List(0), 'm'),
          throwsArgumentError);
      expect(() => emb(vec(0, 0, 0, 0)), throwsArgumentError);
      expect(() => emb(vec(double.nan, 1, 0, 0)), throwsArgumentError);
      expect(() => emb(vec(double.infinity, 1, 0, 0)), throwsArgumentError);
    });

    test('refuses to compare embeddings from different models', () {
      final FaceEmbedding a = emb(vec(1, 0, 0, 0));
      final FaceEmbedding b = emb(vec(1, 0, 0, 0), modelId: 'other');
      expect(() => a.similarity(b), throwsArgumentError);
    });

    test('does not reveal its numbers when printed', () {
      expect(emb(vec(1, 2, 3, 4)).toString(), isNot(contains('0.')));
      expect(emb(vec(1, 2, 3, 4)).toString(), contains('hidden'));
    });
  });

  group('FaceMatcher', () {
    final Float32List alice = vec(1, 0, 0, 0);
    final Float32List bob = vec(0, 1, 0, 0);

    test('matches the right person above the calibrated threshold', () {
      final FaceMatcher m = FaceMatcher(testManifest(threshold: 0.8));
      final MatchOutcome o =
          m.match(emb(vec(0.98, 0.1, 0, 0)), <EnrolledIdentity>[
        person('a', <Float32List>[alice]),
        person('b', <Float32List>[bob]),
      ]);
      expect(o.kind, MatchKind.match);
      expect(o.identityId, 'a');
    });

    test('an unrelated face is an unknown person, never the closest one', () {
      final FaceMatcher m = FaceMatcher(testManifest(threshold: 0.8));
      final MatchOutcome o = m.match(emb(vec(0, 0, 1, 0)), <EnrolledIdentity>[
        person('a', <Float32List>[alice]),
        person('b', <Float32List>[bob]),
      ]);
      expect(o.kind, MatchKind.unknown);
      expect(o.identityId, isNull);
    });

    test('a score just below the threshold is rejected', () {
      final FaceMatcher m = FaceMatcher(testManifest(threshold: 0.8));
      final double y = 0.61237; // cosine with (1,0,0,0) is about 0.79
      final MatchOutcome o = m.match(emb(vec(0.79, y, 0, 0)),
          <EnrolledIdentity>[person('a', <Float32List>[alice])]);
      expect(o.kind, MatchKind.unknown);
    });

    test('two close identities are ambiguous and rejected by the margin', () {
      final FaceMatcher m = FaceMatcher(testManifest(threshold: 0.5, margin: 0.2));
      final MatchOutcome o = m.match(emb(vec(1, 1, 0, 0)), <EnrolledIdentity>[
        person('a', <Float32List>[vec(1, 0.9, 0, 0)]),
        person('b', <Float32List>[vec(0.9, 1, 0, 0)]),
      ]);
      expect(o.kind, MatchKind.unknown);
    });

    test('without a calibrated threshold nothing is compared', () {
      final FaceMatcher m = FaceMatcher(testManifest(calibrated: false));
      final MatchOutcome o = m.match(emb(alice),
          <EnrolledIdentity>[person('a', <Float32List>[alice])]);
      expect(o.kind, MatchKind.cannotCompare);
    });

    test('nobody enrolled cannot be compared (not "unknown")', () {
      final FaceMatcher m = FaceMatcher(testManifest());
      expect(m.match(emb(alice), <EnrolledIdentity>[]).kind,
          MatchKind.cannotCompare);
      expect(
          m.match(emb(alice), <EnrolledIdentity>[person('a', <Float32List>[])]).kind,
          MatchKind.cannotCompare);
    });

    test('templates from another model are not compared', () {
      final FaceMatcher m = FaceMatcher(testManifest());
      final EnrolledIdentity old = EnrolledIdentity(
        id: 'x',
        displayName: 'x',
        createdAt: DateTime.utc(2026),
        samples: <FaceEmbedding>[emb(alice, modelId: 'old-model')],
      );
      expect(m.match(emb(alice), <EnrolledIdentity>[old]).kind,
          MatchKind.cannotCompare);
    });

    test('uses the best of several samples of one person', () {
      final FaceMatcher m = FaceMatcher(testManifest(threshold: 0.9));
      final MatchOutcome o = m.match(emb(alice), <EnrolledIdentity>[
        person('a', <Float32List>[bob, alice]),
      ]);
      expect(o.kind, MatchKind.match);
    });
  });

  group('threshold calibration', () {
    List<double> spread(double from, double to, int n) => <double>[
          for (int i = 0; i < n; i++) from + (to - from) * i / (n - 1),
        ];

    test('refuses to choose a threshold from too little data', () {
      final CalibrationResult r = chooseThreshold(
        genuine: spread(0.6, 0.9, 20),
        impostor: spread(-0.2, 0.3, 500),
        targetFar: 0.001,
      );
      expect(r.sufficient, isFalse);
      expect(r.threshold, isNull);
      expect(r.problem, isNotNull);
    });

    test('meets the target false-accept rate on the supplied data', () {
      final List<double> imp = spread(-0.2, 0.4, 20000);
      final CalibrationResult r = chooseThreshold(
        genuine: spread(0.5, 0.95, 400),
        impostor: imp,
        targetFar: 0.001,
      );
      expect(r.sufficient, isTrue);
      expect(r.achievedFar!, lessThanOrEqualTo(0.001));
      expect(falseAcceptRate(imp, r.threshold!), lessThanOrEqualTo(0.001));
    });

    test('rejects invalid targets and NaN scores', () {
      final List<double> g = spread(0.5, 0.9, 200);
      final List<double> i = spread(-0.2, 0.3, 20000);
      expect(chooseThreshold(genuine: g, impostor: i, targetFar: 0).sufficient,
          isFalse);
      expect(chooseThreshold(genuine: g, impostor: i, targetFar: 1).sufficient,
          isFalse);
      expect(
          chooseThreshold(
                  genuine: <double>[...g, double.nan],
                  impostor: i,
                  targetFar: 0.001)
              .sufficient,
          isFalse);
    });

    test('FAR and FRR helpers count correctly', () {
      expect(falseAcceptRate(<double>[0.1, 0.5, 0.9, 0.95], 0.9), 0.5);
      expect(falseRejectRate(<double>[0.1, 0.5, 0.9, 0.95], 0.9), 0.5);
    });
  });

  group('model manifest', () {
    String json({String sha = '', Map<String, Object?>? cal}) {
      final String h = sha.isEmpty ? 'b' * 64 : sha;
      final String c = cal == null
          ? ''
          : ', "calibration": {'
              '"threshold": ${cal['threshold']}, "margin": 0.05, '
              '"genuine_pairs": ${cal['g']}, "impostor_pairs": ${cal['i']}, '
              '"target_far": 0.001, "data_description": "fixture"}';
      return '{"model_id":"m","sha256":"$h","license":"L","license_url":"u",'
          '"training_data_note":"n","input_size":112,"embedding_dimension":128,'
          '"input_mean":127.5,"input_std":127.5,'
          '"eyes":{"left":[38.3,51.7],"right":[73.5,51.5]}$c}';
    }

    test('parses a valid manifest; uncalibrated by default', () {
      final FaceModelManifest? m = FaceModelManifest.tryParse(json());
      expect(m, isNotNull);
      expect(m!.isCalibrated, isFalse);
    });

    test('accepts calibration only with enough evidence', () {
      final FaceModelManifest? good = FaceModelManifest.tryParse(
          json(cal: <String, Object?>{'threshold': 0.4, 'g': 500, 'i': 20000}));
      expect(good!.isCalibrated, isTrue);
      final FaceModelManifest? thin = FaceModelManifest.tryParse(
          json(cal: <String, Object?>{'threshold': 0.4, 'g': 5, 'i': 50}));
      expect(thin!.isCalibrated, isFalse);
    });

    test('rejects garbage and malformed checksums', () {
      expect(FaceModelManifest.tryParse('not json'), isNull);
      expect(FaceModelManifest.tryParse('[]'), isNull);
      expect(FaceModelManifest.tryParse(json(sha: 'xyz')), isNull);
    });
  });

  group('quality gate', () {
    const FaceQualityGate gate = FaceQualityGate();

    test('flags no face, several faces and bad geometry', () {
      expect(gate.check(<DetectedFace>[]), FaceQualityProblem.noFace);
      expect(gate.check(<DetectedFace>[goodFace(), goodFace()]),
          FaceQualityProblem.multipleFaces);
      expect(gate.check(<DetectedFace>[goodFace()]), isNull);
    });

    test('flags small, cropped, eyeless and turned faces', () {
      DetectedFace f({
        double w = 70,
        double left = 20,
        FacePoint? eye = const FacePoint(40, 50),
        double yaw = 0,
      }) =>
          DetectedFace(
            left: left,
            top: 20,
            width: w,
            height: 70,
            imageWidth: 112,
            imageHeight: 112,
            leftEye: eye,
            rightEye: const FacePoint(72, 50),
            yaw: yaw,
          );
      expect(gate.check(<DetectedFace>[f(w: 10)]), FaceQualityProblem.tooSmall);
      expect(gate.check(<DetectedFace>[f(left: 60)]),
          FaceQualityProblem.partlyOutsideImage);
      expect(gate.check(<DetectedFace>[f(eye: null)]),
          FaceQualityProblem.eyesNotFound);
      expect(gate.check(<DetectedFace>[f(yaw: 40)]),
          FaceQualityProblem.headTurned);
    });

    test('flags dark and bright crops', () {
      expect(gate.checkBrightness(10), FaceQualityProblem.tooDark);
      expect(gate.checkBrightness(250), FaceQualityProblem.tooBright);
      expect(gate.checkBrightness(128), isNull);
    });
  });

  group('alignment', () {
    test('a face already in place is copied unchanged', () {
      final FaceModelManifest m = testManifest();
      final RgbImage src = RgbImage(112, 112, Uint8List(112 * 112 * 3));
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          src.setPixel(x, y, x, y, 7);
        }
      }
      final RgbImage? out = alignFace(src, m.eyeLeft, m.eyeRight, m);
      expect(out, isNotNull);
      expect(out!.width, 112);
      final List<double> p = out.sample(30, 40);
      expect(p[0], closeTo(30, 1.5));
      expect(p[1], closeTo(40, 1.5));
    });

    test('a face twice as large is scaled down by two', () {
      final FaceModelManifest m = testManifest();
      final RgbImage src = RgbImage(224, 224, Uint8List(224 * 224 * 3));
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          src.setPixel(x, y, x, y, 7);
        }
      }
      final FacePoint l = FacePoint(m.eyeLeft.x * 2, m.eyeLeft.y * 2);
      final FacePoint r = FacePoint(m.eyeRight.x * 2, m.eyeRight.y * 2);
      final RgbImage? out = alignFace(src, l, r, m);
      expect(out, isNotNull);
      final List<double> p = out!.sample(20, 30);
      expect(p[0], closeTo(40, 2));
      expect(p[1], closeTo(60, 2));
    });

    test('eyes that are almost on top of each other are refused', () {
      final FaceModelManifest m = testManifest();
      final RgbImage src = RgbImage.filled(112, 112, 100, 100, 100);
      expect(alignFace(src, const FacePoint(50, 50), const FacePoint(51, 50), m),
          isNull);
    });

    test('brightness and tensor normalisation', () {
      final RgbImage grey = RgbImage.filled(4, 4, 200, 200, 200);
      expect(meanLuma(grey), closeTo(200, 0.5));
      final FaceModelManifest m = testManifest();
      final Float32List t = toTensor(RgbImage.filled(2, 2, 255, 0, 127), m);
      expect(t.length, 12);
      expect(t[0], closeTo(1.0, 1e-6));
      expect(t[1], closeTo(-1.0, 1e-6));
    });
  });
}
