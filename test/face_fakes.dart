import 'dart:typed_data';

import 'package:almus_ai/face/face_consent.dart';
import 'package:almus_ai/face/face_dependencies.dart';
import 'package:almus_ai/face/face_matcher.dart';
import 'package:almus_ai/face/face_model_manifest.dart';
import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_ports.dart';
import 'package:almus_ai/face/face_preprocess.dart';
import 'package:almus_ai/face/face_recognition_controller.dart';
import 'package:almus_ai/face/face_vault.dart';
import 'package:almus_ai/face/scan_sound.dart';
import 'package:flutter/widgets.dart';

// Everything in this file is a TEST DOUBLE. None of it recognises anybody:
// "embeddings" are hand-written 4-number vectors chosen by each test.

FaceModelManifest testManifest({
  bool calibrated = true,
  double threshold = 0.5,
  double margin = 0.1,
}) =>
    FaceModelManifest(
      modelId: 'test-model-1',
      sha256: 'a' * 64,
      license: 'TEST FIXTURE ONLY',
      licenseUrl: 'https://example.invalid/none',
      trainingDataNote: 'synthetic test fixture, not a real model',
      inputSize: 112,
      embeddingDimension: 4,
      inputMean: 127.5,
      inputStd: 127.5,
      eyeLeft: const FacePoint(38.29, 51.69),
      eyeRight: const FacePoint(73.53, 51.5),
      calibration: calibrated
          ? ThresholdCalibration(
              threshold: threshold,
              margin: margin,
              genuinePairs: 200,
              impostorPairs: 20000,
              targetFar: 0.01,
              dataDescription: 'synthetic test fixture',
            )
          : null,
    );

Float32List vec(double a, double b, double c, double d) =>
    Float32List.fromList(<double>[a, b, c, d]);

FaceEmbedding emb(Float32List v, {String modelId = 'test-model-1'}) =>
    FaceEmbedding.fromRaw(v, modelId);

class FakeFrame extends CapturedFrame {
  FakeFrame(this.owner) : super('/nonexistent/fake_frame.jpg');

  final FakeCapture owner;

  @override
  Future<void> discard() async => owner.discarded++;
}

class FakeCapture implements FaceCapturePort {
  CameraStatus status = CameraStatus.ready;
  bool throwOnCapture = false;
  int opens = 0;
  int closes = 0;
  int captures = 0;
  int discarded = 0;

  @override
  Future<CameraStatus> open() async {
    opens++;
    return status;
  }

  @override
  Widget buildPreview() => const SizedBox(key: Key('fake-preview'));

  @override
  Future<CapturedFrame> captureStill() async {
    if (throwOnCapture) throw const FaceCaptureException('boom');
    captures++;
    return FakeFrame(this);
  }

  @override
  Future<void> close() async => closes++;
}

class FakeDecoder implements FaceImageDecoder {
  FakeDecoder({this.luma = 128});

  final int luma;
  bool fail = false;

  @override
  Future<RgbImage?> decode(CapturedFrame frame) async =>
      fail ? null : RgbImage.filled(112, 112, luma, luma, luma);
}

DetectedFace goodFace() => const DetectedFace(
      left: 20,
      top: 20,
      width: 70,
      height: 70,
      imageWidth: 112,
      imageHeight: 112,
      leftEye: FacePoint(40, 50),
      rightEye: FacePoint(72, 50),
      yaw: 0,
      pitch: 0,
      roll: 0,
    );

class FakeDetector implements FaceDetectorPort {
  /// Faces for each call; the last entry repeats.
  List<List<DetectedFace>> script = <List<DetectedFace>>[
    <DetectedFace>[goodFace()],
  ];
  int calls = 0;

  @override
  Future<List<DetectedFace>> detect(
    CapturedFrame frame,
    int imageWidth,
    int imageHeight,
  ) async {
    final int i = calls < script.length ? calls : script.length - 1;
    calls++;
    return script[i];
  }

  @override
  Future<void> close() async {}
}

class FakeEmbedder implements FaceEmbedder {
  FakeEmbedder(this.script);

  /// Vectors for each call; the last entry repeats.
  List<Float32List> script;
  int calls = 0;
  bool available = true;
  Duration delay = Duration.zero;

  @override
  bool get isAvailable => available;

  @override
  String get unavailableReason => 'fake unavailable';

  @override
  Future<Float32List> embed(Float32List tensor) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final int i = calls < script.length ? calls : script.length - 1;
    calls++;
    return script[i];
  }

  @override
  Future<void> close() async {}
}

class FakeSoundPlayer implements ScanSoundPlayer {
  int starts = 0;
  int stops = 0;
  bool playing = false;
  int overlaps = 0;
  bool throwOnStart = false;
  Duration startDelay = Duration.zero;

  @override
  Future<void> startLoop() async {
    if (throwOnStart) throw StateError('no audio');
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    if (playing) overlaps++;
    starts++;
    playing = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Future<void> dispose() async {
    playing = false;
  }
}

ScanSoundController makeSound({
  FakeSoundPlayer? player,
  bool enabled = true,
  Duration maxDuration = const Duration(seconds: 15),
}) {
  final ScanSoundController c = ScanSoundController(
    player: player ?? FakeSoundPlayer(),
    store: MemoryScanSoundSettingsStore(enabled: enabled),
    maxDuration: maxDuration,
  );
  return c;
}

class Rig {
  Rig({
    FaceModelManifest? manifest,
    List<Float32List>? embeddings,
    bool soundEnabled = true,
  })  : manifest = manifest ?? testManifest(),
        embedder = FakeEmbedder(
          embeddings ?? <Float32List>[vec(1, 0, 0, 0)],
        ),
        soundPlayer = FakeSoundPlayer() {
    sound = makeSound(player: soundPlayer, enabled: soundEnabled);
    vault = FaceTemplateVault(file: vaultFile, keys: keys);
    runtime = FaceRuntime(embedder: embedder, manifest: this.manifest);
  }

  final FaceModelManifest manifest;
  final FakeEmbedder embedder;
  final FakeSoundPlayer soundPlayer;
  final FakeCapture capture = FakeCapture();
  final FakeDecoder decoder = FakeDecoder();
  final FakeDetector detector = FakeDetector();
  final MemoryVaultFile vaultFile = MemoryVaultFile();
  final MemoryVaultKeyStore keys = MemoryVaultKeyStore();
  final MemoryFaceConsentStore consent = MemoryFaceConsentStore();
  late final ScanSoundController sound;
  late final FaceTemplateVault vault;
  late FaceRuntime runtime;

  Future<void> loadSound() => sound.load();

  Future<void> enrolOne(String name, Float32List v) async {
    await vault.save(manifest.modelId, <EnrolledIdentity>[
      EnrolledIdentity(
        id: 'id-$name',
        displayName: name,
        createdAt: DateTime.utc(2026, 1, 1),
        samples: <FaceEmbedding>[emb(v)],
      ),
    ]);
  }

  FaceRecognitionController recognition({
    Duration scanTimeout = const Duration(seconds: 2),
    Duration attemptPause = const Duration(milliseconds: 10),
    Duration resultVisible = const Duration(seconds: 8),
  }) =>
      FaceRecognitionController(
        runtime: runtime,
        capture: capture,
        decoder: decoder,
        detector: detector,
        vault: vault,
        sound: sound,
        scanTimeout: scanTimeout,
        attemptPause: attemptPause,
        resultVisible: resultVisible,
      );

  FaceDependencies dependencies() => FaceDependencies(
        runtime: runtime,
        capture: capture,
        decoder: decoder,
        detector: detector,
        vault: vault,
        consentStore: consent,
        sound: sound,
      );
}
