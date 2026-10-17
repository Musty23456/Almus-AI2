import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'face_models.dart';
import 'face_preprocess.dart';

/// One still picture from the front camera. It is a face photo, so it is
/// deleted as soon as it has been processed ([discard]).
class CapturedFrame {
  CapturedFrame(this.path);

  final String path;

  Future<void> discard() async {
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Nothing more can be done; Android clears the cache when it needs space.
    }
  }
}

enum CameraStatus { ready, permissionDenied, unavailable }

class FaceCaptureException implements Exception {
  const FaceCaptureException(this.message);
  final String message;
  @override
  String toString() => 'FaceCaptureException($message)';
}

/// The front camera.
abstract class FaceCapturePort {
  Future<CameraStatus> open();

  /// Live preview, or an empty box when the camera is not open.
  Widget buildPreview();

  /// Takes one still. Throws [FaceCaptureException] on failure.
  Future<CapturedFrame> captureStill();

  Future<void> close();
}

/// Reads a captured picture into pixels, with the camera's rotation applied.
abstract class FaceImageDecoder {
  Future<RgbImage?> decode(CapturedFrame frame);
}

/// A face DETECTOR (where is a face?). It never says who it is.
abstract class FaceDetectorPort {
  Future<List<DetectedFace>> detect(
    CapturedFrame frame,
    int imageWidth,
    int imageHeight,
  );

  Future<void> close();
}

/// A face RECOGNITION model: aligned pixels in, embedding out.
abstract class FaceEmbedder {
  /// False when no verified model + inference runtime is installed.
  bool get isAvailable;

  /// Why [isAvailable] is false (shown to the user).
  String get unavailableReason;

  /// [tensor] is size x size x 3 floats, NHWC, already normalised.
  Future<Float32List> embed(Float32List tensor);

  Future<void> close();
}

/// Used when no recognition model can be run. Recognition then reports
/// "unavailable"; it never guesses.
class UnavailableFaceEmbedder implements FaceEmbedder {
  const UnavailableFaceEmbedder(this.unavailableReason);

  @override
  final String unavailableReason;

  @override
  bool get isAvailable => false;

  @override
  Future<Float32List> embed(Float32List tensor) =>
      throw StateError('No recognition model is available.');

  @override
  Future<void> close() async {}
}
