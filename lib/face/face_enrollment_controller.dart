import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'face_consent.dart';
import 'face_matcher.dart';
import 'face_models.dart';
import 'face_pipeline.dart';
import 'face_ports.dart';
import 'face_recognition_controller.dart';
import 'face_vault.dart';
import 'scan_sound.dart';

enum EnrollState { idle, capturing, saving, done, failed }

/// Consent, enrollment, re-enrollment and deletion of face templates.
///
/// - Nothing is captured or stored before consent for the CURRENT wording.
/// - A set of [sampleCount] usable pictures is collected first; the vault is
///   written only when the whole set is good, so a failed or cancelled
///   attempt never damages existing data.
/// - Enrolling a name that already exists replaces its templates
///   (re-enrollment).
class FaceEnrollmentController extends ChangeNotifier {
  FaceEnrollmentController({
    required this.runtime,
    required this.capture,
    required this.decoder,
    required this.detector,
    required this.vault,
    required this.consentStore,
    required this.sound,
    DateTime Function()? clock,
    Random? random,
    this.sampleCount = 3,
    this.captureTimeout = const Duration(seconds: 25),
    this.attemptPause = const Duration(milliseconds: 700),
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final FaceRuntime runtime;
  final FaceCapturePort capture;
  final FaceImageDecoder decoder;
  final FaceDetectorPort detector;
  final FaceTemplateVault vault;
  final FaceConsentStore consentStore;
  final ScanSoundController sound;
  final DateTime Function() _clock;
  final Random _random;
  final int sampleCount;
  final Duration captureTimeout;
  final Duration attemptPause;

  EnrollState _state = EnrollState.idle;
  String _message = '';
  FaceConsent? _consent;
  List<EnrolledIdentity> _identities = const <EnrolledIdentity>[];
  bool _vaultUnreadable = false;
  int _collected = 0;
  int _generation = 0;
  bool _disposed = false;

  EnrollState get state => _state;
  String get message => _message;
  bool get hasConsent => _consent != null && _consent!.isCurrent;
  List<EnrolledIdentity> get identities => _identities;
  bool get vaultUnreadable => _vaultUnreadable;
  int get collected => _collected;
  bool get busy =>
      _state == EnrollState.capturing || _state == EnrollState.saving;

  void _emit(EnrollState s, String message) {
    if (_disposed) return;
    _state = s;
    _message = message;
    notifyListeners();
  }

  Future<void> refresh() async {
    _consent = await consentStore.read();
    final VaultContents c = await vault.load();
    _identities = c.identities;
    _vaultUnreadable = c.unreadable;
    if (!_disposed) notifyListeners();
  }

  Future<void> grantConsent() async {
    final FaceConsent c =
        FaceConsent(version: kFaceConsentVersion, grantedAt: _clock());
    await consentStore.write(c);
    _consent = c;
    if (!_disposed) notifyListeners();
  }

  /// Withdrawing consent deletes every template at once.
  Future<bool> withdrawConsent() async {
    final bool deleted = await deleteAll();
    await consentStore.clear();
    _consent = null;
    if (!_disposed) notifyListeners();
    return deleted;
  }

  /// Deletes every template and the key that protects them.
  Future<bool> deleteAll() async {
    _generation++;
    final bool ok = await vault.deleteAll();
    if (ok) {
      _identities = const <EnrolledIdentity>[];
      _vaultUnreadable = false;
      _emit(EnrollState.idle, 'All face data was deleted from this phone.');
    } else {
      _emit(EnrollState.failed,
          'Face data could not be deleted completely. Try again.');
    }
    return ok;
  }

  /// Deletes one person's templates.
  Future<void> deleteIdentity(String id) async {
    final List<EnrolledIdentity> rest =
        _identities.where((EnrolledIdentity e) => e.id != id).toList();
    if (rest.isEmpty) {
      await deleteAll();
      return;
    }
    final String? modelId = runtime.manifest?.modelId ??
        (rest.first.samples.isNotEmpty ? rest.first.samples.first.modelId : null);
    if (modelId == null) return;
    await vault.save(modelId, rest);
    _identities = rest;
    _emit(EnrollState.idle, 'Deleted.');
  }

  void cancel() {
    _generation++;
    if (busy) _emit(EnrollState.idle, 'Enrollment cancelled. Nothing was changed.');
  }

  /// Captures [sampleCount] usable pictures of ONE person and stores their
  /// templates under [displayName]. Returns true on success.
  Future<bool> enroll(String displayName) async {
    if (_disposed || busy) return false;
    final String name = displayName.trim();
    if (name.isEmpty || name.length > 40) {
      _emit(EnrollState.failed, 'Enter a name of 1 to 40 characters.');
      return false;
    }
    if (!hasConsent) {
      _emit(EnrollState.failed, 'Consent is required before enrolling.');
      return false;
    }
    if (!runtime.usable) {
      _emit(EnrollState.failed,
          runtime.unavailableReason ?? 'No usable recognition model.');
      return false;
    }
    final int gen = ++_generation;
    bool live() => !_disposed && gen == _generation;
    final List<FaceEmbedding> embeddingsOut = <FaceEmbedding>[];
    _collected = 0;
    _emit(EnrollState.capturing, 'Look at the camera.');

    CameraStatus status;
    try {
      status = await capture.open();
    } on Object {
      status = CameraStatus.unavailable;
    }
    if (status != CameraStatus.ready) {
      _emit(EnrollState.failed, 'The front camera is not available.');
      return false;
    }
    unawaited(sound.start());
    final FacePipeline pipeline = FacePipeline(
      manifest: runtime.manifest!,
      decoder: decoder,
      detector: detector,
      embedder: runtime.embedder,
    );
    final double threshold = runtime.manifest!.calibration!.threshold;
    final Stopwatch clock = Stopwatch()..start();
    String hint = 'No face found. Face the camera in good light.';
    try {
      while (live() && embeddingsOut.length < sampleCount) {
        if (clock.elapsed > captureTimeout) {
          _emit(EnrollState.failed, 'Enrollment timed out. $hint');
          return false;
        }
        CapturedFrame frame;
        try {
          frame = await capture.captureStill();
        } on Object {
          _emit(EnrollState.failed, 'The camera could not take a picture.');
          return false;
        }
        if (!live()) {
          await frame.discard();
          return false;
        }
        final PipelineResult r = await pipeline.process(frame);
        if (!live()) return false;
        if (r.embedding != null) {
          final FaceEmbedding e = r.embedding!;
          // Every picture must look like the first one, so two different
          // people cannot be enrolled under one name by accident.
          if (embeddingsOut.isNotEmpty &&
              e.similarity(embeddingsOut.first) < threshold) {
            _emit(EnrollState.failed,
                'The pictures do not look like the same person. Enrollment stopped.');
            return false;
          }
          embeddingsOut.add(e);
          _collected = embeddingsOut.length;
          _emit(EnrollState.capturing,
              'Captured $_collected of $sampleCount. Slightly change your pose.');
        } else if (r.problem != null) {
          hint = describeQualityProblem(r.problem!);
          _emit(EnrollState.capturing, hint);
        } else {
          _emit(EnrollState.failed, 'Enrollment failed. Please try again.');
          return false;
        }
        await Future<void>.delayed(attemptPause);
      }
      if (!live()) return false;
    } finally {
      await sound.stop();
      try {
        await capture.close();
      } on Object {
        // Already closed.
      }
    }

    _emit(EnrollState.saving, 'Saving encrypted face data…');
    try {
      final String modelId = runtime.manifest!.modelId;
      final VaultContents current = await vault.load();
      // Templates from another model cannot be compared; they are replaced.
      final List<EnrolledIdentity> keep = current.modelId == modelId
          ? current.identities
              .where((EnrolledIdentity i) => i.displayName != name)
              .toList()
          : <EnrolledIdentity>[];
      keep.add(EnrolledIdentity(
        id: _newId(),
        displayName: name,
        createdAt: _clock(),
        samples: embeddingsOut,
      ));
      await vault.save(modelId, keep);
      _identities = keep;
      _vaultUnreadable = false;
      _emit(EnrollState.done, 'Enrolled $name. No camera pictures were kept.');
      return true;
    } on Object {
      _emit(EnrollState.failed, 'Face data could not be saved.');
      return false;
    }
  }

  String _newId() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 8; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
