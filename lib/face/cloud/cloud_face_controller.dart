import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/app_settings.dart';
import '../face_models.dart';
import '../face_ports.dart';
import '../face_preprocess.dart';
import 'cloud_face_api.dart';
import 'cloud_face_storage.dart';

enum CloudScanState {
  ready,
  capturing,
  uploading,
  verified,
  notVerified,
  failed,
  cameraUnavailable,
}

String cloudScanTitle(CloudScanState s) {
  switch (s) {
    case CloudScanState.ready:
      return 'READY';
    case CloudScanState.capturing:
      return 'LOOK AT THE CAMERA';
    case CloudScanState.uploading:
      return 'CHECKING WITH THE CLOUD';
    case CloudScanState.verified:
      return 'IDENTITY VERIFIED';
    case CloudScanState.notVerified:
      return 'NOT VERIFIED';
    case CloudScanState.failed:
      return 'CHECK FAILED';
    case CloudScanState.cameraUnavailable:
      return 'CAMERA UNAVAILABLE';
  }
}

Future<Uint8List> _readFrameFile(CapturedFrame frame) => File(frame.path).readAsBytes();

/// Cloud 1:1 face verification (Luxand through the Almus backend).
///
/// Rules this class keeps:
/// - Nothing is captured or sent before consent for the CURRENT wording.
/// - A photo is only uploaded when the on-device detector sees exactly one
///   usable face, so bad photos do not cost a request.
/// - Camera files are always deleted; photo bytes live in memory only.
/// - "verified" is reachable only when the backend answers verified == true.
///   Any error, timeout or odd answer is a failure, never a match.
/// - Deleting is reported as done only after the service deleted the person.
class CloudFaceController extends ChangeNotifier {
  CloudFaceController({
    required this.api,
    required this.settings,
    required this.capture,
    required this.decoder,
    required this.detector,
    required this.linkStore,
    required this.consentStore,
    this.gate = const FaceQualityGate(),
    this.enrollPhotos = 3,
    this.captureTimeout = const Duration(seconds: 20),
    this.attemptPause = const Duration(milliseconds: 600),
    this.resultVisible = const Duration(seconds: 8),
    Future<Uint8List> Function(CapturedFrame frame)? readFrame,
    DateTime Function()? clock,
  })  : _readFrame = readFrame ?? _readFrameFile,
        _clock = clock ?? DateTime.now;

  final CloudFaceApi api;

  /// Read at call time, so a changed backend address or token is used.
  final AppSettings Function() settings;
  final FaceCapturePort capture;
  final FaceImageDecoder decoder;
  final FaceDetectorPort detector;
  final CloudFaceLinkStore linkStore;
  final CloudFaceConsentStore consentStore;
  final FaceQualityGate gate;
  final int enrollPhotos;
  final Duration captureTimeout;
  final Duration attemptPause;
  final Duration resultVisible;
  final Future<Uint8List> Function(CapturedFrame frame) _readFrame;
  final DateTime Function() _clock;

  CloudScanState _state = CloudScanState.ready;
  String _message = 'Ready.';
  CloudFaceConsent? _consent;
  CloudFaceLink? _link;
  String? _verifiedName;
  int _generation = 0;
  bool _disposed = false;
  bool _cameraOpen = false;
  bool _busy = false;
  Timer? _resetTimer;

  CloudScanState get state => _state;
  String get message => _message;
  CloudFaceLink? get link => _link;
  bool get hasConsent => _consent != null && _consent!.isCurrent;
  bool get busy => _busy;
  bool get cameraOpen => _cameraOpen;

  /// Set only while [state] is [CloudScanState.verified].
  String? get verifiedName => _verifiedName;

  void _set(CloudScanState s, String message, {String? verified}) {
    if (_disposed) return;
    _state = s;
    _message = message;
    _verifiedName = s == CloudScanState.verified ? verified : null;
    notifyListeners();
  }

  Future<void> refresh() async {
    _consent = await consentStore.read();
    _link = await linkStore.read();
    if (!_disposed) notifyListeners();
  }

  Future<void> grantConsent() async {
    final CloudFaceConsent c =
        CloudFaceConsent(version: kCloudFaceConsentVersion, grantedAt: _clock());
    await consentStore.write(c);
    _consent = c;
    if (!_disposed) notifyListeners();
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

  Future<void> _closeCamera() async {
    if (!_cameraOpen) return;
    _cameraOpen = false;
    try {
      await capture.close();
    } on Object {
      // Already closed.
    }
  }

  String _cameraMessage(CameraStatus s) => s == CameraStatus.permissionDenied
      ? 'Camera permission was denied. Allow it in Android settings.'
      : 'The front camera is not available.';

  /// Takes stills until one has exactly one usable face, and returns its JPEG
  /// bytes. The camera file is deleted in every case. Returns null when
  /// cancelled or timed out ([hint] has been called with the last problem).
  Future<Uint8List?> _captureUsable(bool Function() live, void Function(String) hint) async {
    final Stopwatch clock = Stopwatch()..start();
    while (live() && clock.elapsed < captureTimeout) {
      CapturedFrame frame;
      try {
        frame = await capture.captureStill();
      } on Object {
        throw const CloudFaceException('capture_failed', 'The camera could not take a picture.');
      }
      try {
        if (!live()) return null;
        final RgbImage? image = await decoder.decode(frame);
        if (image == null) {
          hint('The picture could not be read.');
        } else {
          final List<DetectedFace> faces =
              await detector.detect(frame, image.width, image.height);
          final FaceQualityProblem? problem = gate.check(faces);
          if (problem == null) {
            final Uint8List bytes = await _readFrame(frame);
            if (bytes.isNotEmpty) return bytes;
            hint('The picture could not be read.');
          } else {
            hint(describeQualityProblem(problem));
          }
        }
      } finally {
        await frame.discard();
      }
      if (!live()) return null;
      await Future<void>.delayed(attemptPause);
    }
    return null;
  }

  AppSettings _settingsOrThrow() {
    final AppSettings s = settings();
    if (normalizeBackendUrl(s.backendUrl) == null || s.accessToken.isEmpty) {
      throw const CloudFaceException('not_configured',
          'Set your backend address and access token in Settings first.');
    }
    return s;
  }

  String _failText(Object e) => e is CloudFaceException
      ? e.message
      : 'Something went wrong. Please try again.';

  /// Enrols ONE person (replacing any existing one) from [enrollPhotos]
  /// usable stills. Returns true on success.
  Future<bool> enroll(String displayName) async {
    if (_disposed || _busy) return false;
    final String name = displayName.trim();
    if (name.isEmpty || name.length > 40) {
      _set(CloudScanState.failed, 'Enter a name of 1 to 40 characters.');
      return false;
    }
    if (!hasConsent) {
      _set(CloudScanState.failed, 'Consent is required before enrolling.');
      return false;
    }
    _resetTimer?.cancel();
    _busy = true;
    final int gen = ++_generation;
    bool live() => !_disposed && gen == _generation;
    try {
      final AppSettings s = _settingsOrThrow();

      // One enrolled person at a time. The old one is deleted at the service
      // FIRST; if that fails nothing changes, so no orphan copy is left behind.
      final CloudFaceLink? old = _link ?? await linkStore.read();
      if (old != null) {
        _set(CloudScanState.uploading, 'Removing the previous enrolled face…');
        await api.remove(s, old.personId);
        await linkStore.clear();
        _link = null;
        if (!live()) return false;
      }

      final CameraStatus status = await _openCamera();
      if (!live()) return false;
      if (status != CameraStatus.ready) {
        _set(CloudScanState.cameraUnavailable, _cameraMessage(status));
        return false;
      }

      final List<Uint8List> photos = <Uint8List>[];
      String hint = 'No face found. Face the camera in good light.';
      _set(CloudScanState.capturing, 'Look at the camera.');
      while (live() && photos.length < enrollPhotos) {
        final Uint8List? p = await _captureUsable(live, (String h) {
          hint = h;
          if (live()) _set(CloudScanState.capturing, h);
        });
        if (!live()) return false;
        if (p == null) {
          _set(CloudScanState.failed, 'Enrollment timed out. $hint');
          return false;
        }
        photos.add(p);
        _set(CloudScanState.capturing,
            'Captured ${photos.length} of $enrollPhotos. Slightly change your pose.');
        await Future<void>.delayed(attemptPause);
      }
      await _closeCamera();
      if (!live()) return false;

      _set(CloudScanState.uploading, 'Sending to the face service…');
      final String personId = await api.enroll(s, photos.first);
      int stored = 1;
      for (final Uint8List extra in photos.skip(1)) {
        try {
          await api.addPhoto(s, personId, extra);
          stored++;
        } on CloudFaceException {
          // The person exists with fewer photos; matching still works.
        }
      }
      try {
        await linkStore.write(
            CloudFaceLink(name: name, personId: personId, createdAt: _clock()));
      } on Object {
        // Do not leave a face at the service that this phone cannot find again.
        try {
          await api.remove(s, personId);
        } on Object {
          // Reported below.
        }
        _set(CloudScanState.failed, 'Enrollment could not be saved on this phone.');
        return false;
      }
      _link = CloudFaceLink(name: name, personId: personId, createdAt: _clock());
      _set(
        CloudScanState.ready,
        stored == enrollPhotos
            ? 'Enrolled $name. No camera photos were kept.'
            : 'Enrolled $name with $stored of $enrollPhotos photos. Accuracy may be lower.',
      );
      return true;
    } on Object catch (e) {
      if (live()) _set(CloudScanState.failed, _failText(e));
      return false;
    } finally {
      _busy = false;
      await _closeCamera();
      if (!_disposed) notifyListeners();
    }
  }

  /// Asks the backend whether cloud verification is set up. Sends no photo.
  Future<CloudFaceStatus> backendStatus() => api.status(_settingsOrThrow());

  /// One 1:1 check. Uploads at most one photo.
  Future<void> verify() async {
    if (_disposed || _busy) return;
    if (!hasConsent) {
      _set(CloudScanState.failed, 'Consent is required first.');
      return;
    }
    final CloudFaceLink? who = _link;
    if (who == null) {
      _set(CloudScanState.failed, 'Nobody is enrolled yet.');
      return;
    }
    _resetTimer?.cancel();
    _busy = true;
    final int gen = ++_generation;
    bool live() => !_disposed && gen == _generation;
    try {
      final AppSettings s = _settingsOrThrow();
      final CameraStatus status = await _openCamera();
      if (!live()) return;
      if (status != CameraStatus.ready) {
        _set(CloudScanState.cameraUnavailable, _cameraMessage(status));
        return;
      }
      String hint = 'No face found. Face the camera in good light.';
      _set(CloudScanState.capturing, 'Look at the camera.');
      final Uint8List? photo = await _captureUsable(live, (String h) {
        hint = h;
        if (live()) _set(CloudScanState.capturing, h);
      });
      if (!live()) return;
      if (photo == null) {
        _set(CloudScanState.failed, 'Scan timed out. $hint');
        return;
      }
      await _closeCamera();
      _set(CloudScanState.uploading, 'Checking with the face service…');
      final bool ok = await api.verify(s, who.personId, photo);
      if (!live()) return;
      if (ok) {
        _set(CloudScanState.verified, 'Match found.', verified: who.name);
      } else {
        _set(CloudScanState.notVerified, 'This face did not match the enrolled person.');
      }
      _scheduleReset();
    } on Object catch (e) {
      if (live()) _set(CloudScanState.failed, _failText(e));
    } finally {
      _busy = false;
      await _closeCamera();
      if (!_disposed) notifyListeners();
    }
  }

  /// Deletes the face at the service, then on this phone. Returns true only
  /// when the service confirmed the deletion (or nothing was enrolled).
  Future<bool> deleteCloudFace() async {
    if (_disposed || _busy) return false;
    _busy = true;
    _generation++;
    _resetTimer?.cancel();
    try {
      final CloudFaceLink? old = _link ?? await linkStore.read();
      if (old != null) {
        final AppSettings s = _settingsOrThrow();
        await api.remove(s, old.personId);
      }
      await linkStore.clear();
      _link = null;
      _set(CloudScanState.ready, 'Your face was deleted from the cloud service and this phone.');
      return true;
    } on Object catch (e) {
      _set(CloudScanState.failed,
          'NOT deleted. ${_failText(e)} Your face may still be stored at the service; try again.');
      return false;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Withdrawing consent deletes the cloud face first. Consent is cleared only
  /// when the deletion succeeded, so a failed deletion can be retried.
  Future<bool> withdrawConsent() async {
    final bool deleted = await deleteCloudFace();
    if (!deleted) return false;
    await consentStore.clear();
    _consent = null;
    if (!_disposed) notifyListeners();
    return true;
  }

  void _scheduleReset() {
    _resetTimer?.cancel();
    _resetTimer = Timer(resultVisible, () {
      if (_disposed) return;
      if (_state == CloudScanState.verified || _state == CloudScanState.notVerified) {
        _set(CloudScanState.ready, 'Ready.');
      }
    });
  }

  Future<void> cancel() async {
    _generation++;
    _resetTimer?.cancel();
    await _closeCamera();
    if (!_disposed) _set(CloudScanState.ready, 'Cancelled. Nothing was sent.');
  }

  Future<void> onBackground() async {
    _generation++;
    _resetTimer?.cancel();
    await _closeCamera();
    if (!_disposed && _state != CloudScanState.uploading) {
      _set(CloudScanState.ready, 'Ready.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _resetTimer?.cancel();
    if (_cameraOpen) {
      _cameraOpen = false;
      unawaited(capture.close());
    }
    super.dispose();
  }
}
