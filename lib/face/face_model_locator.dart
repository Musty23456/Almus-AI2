import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'face_model_manifest.dart';
import 'face_ports.dart';
import 'face_recognition_controller.dart';

/// Why recognition can or cannot run in this build, in plain words.
enum FaceModelStatus {
  notInstalled,
  invalidManifest,
  modelFileMissing,
  hashMismatch,
  notCalibrated,

  /// Files are fine, but this build has no inference runtime to run them.
  runtimeMissing,
  ready,
}

class FaceModelCheck {
  const FaceModelCheck(this.status, this.manifest);

  final FaceModelStatus status;
  final FaceModelManifest? manifest;

  String get explanation {
    switch (status) {
      case FaceModelStatus.notInstalled:
        return 'No face recognition model is installed. This app does not '
            'bundle one, because no model with a clear licence for this use '
            'has been verified (see docs/FACE_MODEL_LICENSING.md).';
      case FaceModelStatus.invalidManifest:
        return 'The model description file (manifest.json) is invalid.';
      case FaceModelStatus.modelFileMissing:
        return 'The model file named by the manifest is missing.';
      case FaceModelStatus.hashMismatch:
        return 'The model file does not match the checksum in the manifest, '
            'so it was not loaded.';
      case FaceModelStatus.notCalibrated:
        return 'The model has no measured, calibrated threshold, so matching '
            'is disabled.';
      case FaceModelStatus.runtimeMissing:
        return 'A model is installed, but this build has no inference runtime '
            'bound to it yet (see docs/FACE_MODEL_LICENSING.md, "Binding a '
            'model").';
      case FaceModelStatus.ready:
        return 'Ready.';
    }
  }
}

/// Looks for `<app support>/face_model/manifest.json` and the model file it
/// named `model.tflite`, verifies the SHA-256 and the
/// calibration, and reports what is missing.
class FaceModelLocator {
  FaceModelLocator(this.directory);

  final Directory directory;

  static Future<FaceModelLocator> standard() async {
    final Directory base = await getApplicationSupportDirectory();
    return FaceModelLocator(Directory('${base.path}/face_model'));
  }

  Future<FaceModelCheck> check({bool runtimeAvailable = false}) async {
    final File manifestFile = File('${directory.path}/manifest.json');
    if (!await manifestFile.exists()) {
      return const FaceModelCheck(FaceModelStatus.notInstalled, null);
    }
    final FaceModelManifest? manifest =
        FaceModelManifest.tryParse(await manifestFile.readAsString());
    if (manifest == null) {
      return const FaceModelCheck(FaceModelStatus.invalidManifest, null);
    }
    final File model = File('${directory.path}/model.tflite');
    if (!await model.exists()) {
      return FaceModelCheck(FaceModelStatus.modelFileMissing, manifest);
    }
    final String digest =
        crypto.sha256.convert(await model.readAsBytes()).toString();
    if (digest != manifest.sha256) {
      return FaceModelCheck(FaceModelStatus.hashMismatch, manifest);
    }
    if (!manifest.isCalibrated) {
      return FaceModelCheck(FaceModelStatus.notCalibrated, manifest);
    }
    if (!runtimeAvailable) {
      return FaceModelCheck(FaceModelStatus.runtimeMissing, manifest);
    }
    return FaceModelCheck(FaceModelStatus.ready, manifest);
  }
}

/// Builds the runtime for this build. There is NO inference runtime bound in
/// Phase 6 (no verified model exists), so this always reports unavailable,
/// with the precise reason. Binding a model means returning a
/// [FaceRuntime] with a real [FaceEmbedder] when `check` says ready.
Future<FaceRuntime> buildFaceRuntime({FaceModelLocator? locator}) async {
  try {
    final FaceModelLocator l = locator ?? await FaceModelLocator.standard();
    final FaceModelCheck check = await l.check(runtimeAvailable: false);
    return FaceRuntime(
      embedder: UnavailableFaceEmbedder(check.explanation),
      manifest: check.manifest,
      unavailableReason: check.explanation,
    );
  } on Object {
    return const FaceRuntime.unavailable(
      'The recognition model could not be checked.',
    );
  }
}

/// Phase 9 stored a plain JPEG of the user's face. Phase 6 never stores
/// pictures, so that file and its preference are removed once.
class LegacyFaceSamplePurger {
  const LegacyFaceSamplePurger();

  static const String _prefKey = 'phase9_face_enrollment_path';
  static const String _fileName = 'almus_face_sample.jpg';

  /// Returns true when something was removed.
  Future<bool> purge({Directory? supportDirectory}) async {
    bool removed = false;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? saved = prefs.getString(_prefKey);
      if (saved != null) {
        final File f = File(saved);
        if (await f.exists()) {
          await f.delete();
          removed = true;
        }
        await prefs.remove(_prefKey);
        removed = true;
      }
      final Directory dir =
          supportDirectory ?? await getApplicationSupportDirectory();
      final File fixed = File('${dir.path}/$_fileName');
      if (await fixed.exists()) {
        await fixed.delete();
        removed = true;
      }
    } on Object {
      return removed;
    }
    return removed;
  }
}

/// For tests and the report: the labels the UI uses for each scan state.
String scanStateTitle(ScanState s) {
  switch (s) {
    case ScanState.ready:
      return 'READY TO SCAN';
    case ScanState.scanning:
      return 'SCANNING';
    case ScanState.faceDetected:
      return 'FACE DETECTED';
    case ScanState.matching:
      return 'MATCHING';
    case ScanState.verified:
      return 'IDENTITY VERIFIED';
    case ScanState.unknown:
      return 'UNKNOWN IDENTITY';
    case ScanState.failed:
      return 'RECOGNITION FAILED';
    case ScanState.cameraUnavailable:
      return 'CAMERA UNAVAILABLE';
    case ScanState.modelUnavailable:
      return 'RECOGNITION UNAVAILABLE';
  }
}
