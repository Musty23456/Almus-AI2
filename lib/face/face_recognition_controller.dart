import 'dart:async';

import 'package:flutter/foundation.dart';

import 'face_matcher.dart';
import 'face_model_manifest.dart';
import 'face_models.dart';
import 'face_pipeline.dart';
import 'face_ports.dart';
import 'face_vault.dart';
import 'scan_sound.dart';

/// What the screen shows. [verified] is reachable ONLY through a successful
/// calibrated match; nothing else sets it.
enum ScanState {
  ready,
  scanning,
  faceDetected,
  matching,
  verified,
  unknown,
  failed,
  cameraUnavailable,
  modelUnavailable,
}

/// Why a model can or cannot be used, for the screen and the report.
class FaceRuntime {
  const FaceRuntime({
    required this.embedder,
    required this.manifest,
    this.unavailableReason,
  });

  const FaceRuntime.unavailable(String reason)
      : embedder = const UnavailableFaceEmbedder('unavailable'),
        manifest = null,
        unavailableReason = reason;

  final FaceEmbedder embedder;
  final FaceModelManifest? manifest;
  final String? unavailableReason;

  bool get usable =>
      manifest != null &&
      manifest!.isCalibrated &&
      embedder.isAvailable &&
      unavailableReason == null;
}

/// Runs one scan at a time. Camera pictures are processed one by one and
/// deleted; embeddings are compared in memory and never logged.
class FaceRecognitionController extends ChangeNotifier {
  FaceRecognitionController({
    required this.runtime,
    required this.capture,
    required this.decoder,
    required this.detector,
    required this.vault,
    required this.sound,
    this.scanTimeout = const Duration(seconds: 12),
    this.attemptPause = const Duration(milliseconds: 600),
    this.resultVisible = const Duration(seconds: 8),
  });

  final FaceRuntime runtime;
  final FaceCapturePort capture;
  final FaceImageDecoder decoder;
  final FaceDetectorPort detector;
  final FaceTemplateVault vault;
  final ScanSoundController sound;
  final Duration scanTimeout;
  final Duration attemptPause;
  final Duration resultVisible;

  ScanState _state = ScanState.ready;
  String _message = 'Ready to scan.';
  String? _verifiedName;
  int _generation = 0;
  bool _disposed = false;
  bool _cameraOpen = false;
  Timer? _resetTimer;

  ScanState get state => _state;
  String get message => _message;

  /// Set only while [state] is [ScanState.verified].
  String? get verifiedName => _verifiedName;
  bool get cameraOpen => _cameraOpen;
  bool get isBusy =>
      _state == ScanState.scanning ||
      _state == ScanState.faceDetected ||
      _state == ScanState.matching;

  void _set(ScanState s, String message, {String? verified}) {
    if (_disposed) return;
    _state = s;
    _message = message;
    _verifiedName = s == ScanState.verified ? verified : null;
    notifyListeners();
  }

  /// Opens the camera for the preview. Does not scan.
  Future<void> prepare() async {
    if (_disposed || isBusy) return;
    if (!runtime.usable) {
      _set(
        ScanState.modelUnavailable,
        runtime.unavailableReason ??
            'No verified, calibrated recognition model is installed.',
      );
      return;
    }
    final CameraStatus status = await _openCamera();
    if (_disposed) return;
    if (status == CameraStatus.ready) {
      _set(ScanState.ready, 'Ready to scan.');
    } else {
      _set(
        ScanState.cameraUnavailable,
        status == CameraStatus.permissionDenied
            ? 'Camera permission was denied. Allow it in Android settings.'
            : 'The front camera is not available.',
      );
    }
  }

  Future<CameraStatus> _openCamera() async {
    if (_cameraOpen) return CameraStatus.ready;
    CameraStatus status;
    try {
      status = await capture.open();
    } on Object {
      status = CameraStatus.unavailable;
    }
    _cameraOpen = status == CameraStatus.ready;
    return status;
  }

  /// Starts one scan. Ignored while another scan is running.
  Future<void> scan() async {
    if (_disposed || isBusy) return;
    _resetTimer?.cancel();
    if (!runtime.usable) {
      _set(
        ScanState.modelUnavailable,
        runtime.unavailableReason ??
            'No verified, calibrated recognition model is installed.',
      );
      return;
    }
    final int gen = ++_generation;
    bool live() => !_disposed && gen == _generation;

    final CameraStatus status = await _openCamera();
    if (!live()) return;
    if (status != CameraStatus.ready) {
      _set(
        ScanState.cameraUnavailable,
        status == CameraStatus.permissionDenied
            ? 'Camera permission was denied. Allow it in Android settings.'
            : 'The front camera is not available.',
      );
      return;
    }

    final VaultContents contents = await vault.load();
    if (!live()) return;
    if (contents.unreadable) {
      _set(ScanState.failed,
          'Saved face data cannot be read. Delete it and enrol again.');
      return;
    }
    if (contents.identities.every((EnrolledIdentity e) => e.samples.isEmpty)) {
      _set(ScanState.failed, 'Nobody is enrolled yet.');
      return;
    }

    _set(ScanState.scanning, 'Scanning…');
    // The sound starts here: the camera is open and the scan really begins.
    unawaited(sound.start());

    final FaceModelManifest manifest = runtime.manifest!;
    final FacePipeline pipeline = FacePipeline(
      manifest: manifest,
      decoder: decoder,
      detector: detector,
      embedder: runtime.embedder,
    );
    final Stopwatch clock = Stopwatch()..start();
    String lastProblem = 'No face found. Face the camera in good light.';
    try {
      while (live() && clock.elapsed < scanTimeout) {
        CapturedFrame frame;
        try {
          frame = await capture.captureStill();
        } on Object {
          if (!live()) return;
          _set(ScanState.failed, 'The camera could not take a picture.');
          return;
        }
        if (!live()) {
          await frame.discard();
          return;
        }
        final PipelineResult result = await pipeline.process(
          frame,
          onFaceDetected: () {
            if (live()) _set(ScanState.faceDetected, 'Face detected.');
          },
        );
        if (!live()) return;
        if (result.embedding != null) {
          _set(ScanState.matching, 'Matching…');
          final MatchOutcome outcome =
              FaceMatcher(manifest).match(result.embedding!, contents.identities);
          if (!live()) return;
          switch (outcome.kind) {
            case MatchKind.match:
              final String name = contents.identities
                  .firstWhere((EnrolledIdentity e) => e.id == outcome.identityId)
                  .displayName;
              _set(ScanState.verified, 'Match found.', verified: name);
              _scheduleReset();
              return;
            case MatchKind.unknown:
              _set(ScanState.unknown, 'Unknown person. No enrolled face matched.');
              _scheduleReset();
              return;
            case MatchKind.cannotCompare:
              _set(ScanState.failed,
                  outcome.reason ?? 'The faces could not be compared.');
              return;
          }
        }
        if (result.problem != null) {
          lastProblem = describeQualityProblem(result.problem!);
        } else if (result.failure != null) {
          _set(ScanState.failed, 'Recognition failed. Please try again.');
          return;
        }
        // Back to plain scanning while we look again.
        if (_state != ScanState.scanning) _set(ScanState.scanning, 'Scanning…');
        await Future<void>.delayed(attemptPause);
      }
      if (live()) {
        _set(ScanState.failed, 'Scan timed out. $lastProblem');
      }
    } finally {
      // Always stop the sound when the scan ends, however it ends.
      await sound.stop();
    }
  }

  /// Cancels a scan in progress. Nothing is reported as a result.
  Future<void> cancel() async {
    _generation++;
    _resetTimer?.cancel();
    await sound.stop();
    if (!_disposed && _state != ScanState.modelUnavailable) {
      _set(ScanState.ready, 'Scan cancelled.');
    }
  }

  void _scheduleReset() {
    _resetTimer?.cancel();
    _resetTimer = Timer(resultVisible, () {
      if (_disposed) return;
      if (_state == ScanState.verified || _state == ScanState.unknown) {
        _set(ScanState.ready, 'Ready to scan.');
      }
    });
  }

  /// The app left the foreground: stop everything and release the camera.
  Future<void> onBackground() async {
    _generation++;
    _resetTimer?.cancel();
    await sound.stop();
    if (_cameraOpen) {
      _cameraOpen = false;
      try {
        await capture.close();
      } on Object {
        // Already closed.
      }
    }
    if (!_disposed && _state != ScanState.modelUnavailable) {
      _set(ScanState.ready, 'Ready to scan.');
    }
  }

  Future<void> onForeground() => prepare();

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _resetTimer?.cancel();
    unawaited(sound.stop());
    if (_cameraOpen) {
      _cameraOpen = false;
      unawaited(capture.close());
    }
    super.dispose();
  }
}
