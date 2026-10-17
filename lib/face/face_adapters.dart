import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_models.dart';
import 'face_ports.dart';
import 'face_preprocess.dart';

/// Front camera through the Flutter `camera` plugin. Stills only: no video,
/// no audio, nothing is recorded.
class CameraFacePort implements FaceCapturePort {
  CameraController? _controller;

  @override
  Future<CameraStatus> open() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      CameraDescription? front;
      for (final CameraDescription c in cameras) {
        if (c.lensDirection == CameraLensDirection.front) {
          front = c;
          break;
        }
      }
      if (front == null) return CameraStatus.unavailable;
      final CameraController controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      _controller = controller;
      return CameraStatus.ready;
    } on CameraException catch (e) {
      if (e.code == 'CameraAccessDenied' ||
          e.code == 'CameraAccessDeniedWithoutPrompt' ||
          e.code == 'CameraAccessRestricted') {
        return CameraStatus.permissionDenied;
      }
      return CameraStatus.unavailable;
    } on Object {
      return CameraStatus.unavailable;
    }
  }

  @override
  Widget buildPreview() {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return CameraPreview(c);
  }

  @override
  Future<CapturedFrame> captureStill() async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) {
      throw const FaceCaptureException('Camera not ready.');
    }
    try {
      final XFile file = await c.takePicture();
      return CapturedFrame(file.path);
    } on CameraException {
      throw const FaceCaptureException('Capture failed.');
    }
  }

  @override
  Future<void> close() async {
    final CameraController? c = _controller;
    _controller = null;
    await c?.dispose();
  }
}

/// Reads the JPEG and applies its EXIF rotation, so pixel coordinates match
/// what ML Kit reports.
class ImagePackageDecoder implements FaceImageDecoder {
  const ImagePackageDecoder();

  @override
  Future<RgbImage?> decode(CapturedFrame frame) async {
    try {
      final Uint8List bytes = await File(frame.path).readAsBytes();
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final img.Image upright = img.bakeOrientation(decoded);
      final Uint8List rgb = Uint8List(upright.width * upright.height * 3);
      int o = 0;
      for (int y = 0; y < upright.height; y++) {
        for (int x = 0; x < upright.width; x++) {
          final img.Pixel p = upright.getPixel(x, y);
          rgb[o++] = p.r.toInt();
          rgb[o++] = p.g.toInt();
          rgb[o++] = p.b.toInt();
        }
      }
      return RgbImage(upright.width, upright.height, rgb);
    } on Object {
      return null;
    }
  }
}

/// Google ML Kit face DETECTION (on device). It finds faces and eye
/// positions. It cannot tell who a face belongs to.
class MlKitFaceDetectorPort implements FaceDetectorPort {
  MlKitFaceDetectorPort()
      : _detector = FaceDetector(
          options: FaceDetectorOptions(
            enableLandmarks: true,
            performanceMode: FaceDetectorMode.accurate,
            minFaceSize: 0.15,
          ),
        );

  final FaceDetector _detector;

  @override
  Future<List<DetectedFace>> detect(
    CapturedFrame frame,
    int imageWidth,
    int imageHeight,
  ) async {
    final List<Face> faces =
        await _detector.processImage(InputImage.fromFilePath(frame.path));
    return <DetectedFace>[
      for (final Face f in faces) _convert(f, imageWidth, imageHeight),
    ];
  }

  DetectedFace _convert(Face f, int w, int h) {
    FacePoint? eye(FaceLandmarkType t) {
      final FaceLandmark? l = f.landmarks[t];
      if (l == null) return null;
      return FacePoint(l.position.x.toDouble(), l.position.y.toDouble());
    }

    FacePoint? a = eye(FaceLandmarkType.leftEye);
    FacePoint? b = eye(FaceLandmarkType.rightEye);
    // Order by picture position so alignment does not depend on mirroring.
    if (a != null && b != null && a.x > b.x) {
      final FacePoint t = a;
      a = b;
      b = t;
    }
    return DetectedFace(
      left: f.boundingBox.left,
      top: f.boundingBox.top,
      width: f.boundingBox.width,
      height: f.boundingBox.height,
      imageWidth: w,
      imageHeight: h,
      leftEye: a,
      rightEye: b,
      yaw: f.headEulerAngleY,
      pitch: f.headEulerAngleX,
      roll: f.headEulerAngleZ,
    );
  }

  @override
  Future<void> close() => _detector.close();
}
