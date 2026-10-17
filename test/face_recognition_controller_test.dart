import 'dart:typed_data';

import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_ports.dart';
import 'package:almus_ai/face/face_recognition_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

/// Records every state and checks the rule that matters most: a verified name
/// exists only while the state is `verified`.
class Recorder {
  Recorder(this.c) {
    c.addListener(() {
      states.add(c.state);
      if (c.verifiedName != null && c.state != ScanState.verified) {
        violation = true;
      }
      if (c.state == ScanState.verified && c.verifiedName == null) {
        violation = true;
      }
    });
  }

  final FaceRecognitionController c;
  final List<ScanState> states = <ScanState>[];
  bool violation = false;
}

void main() {
  test('verified only after a calibrated match; states in order', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    final Recorder rec = Recorder(c);
    await c.scan();
    expect(c.state, ScanState.verified);
    expect(c.verifiedName, 'Amina');
    expect(rec.violation, isFalse);
    final int firstVerified = rec.states.indexOf(ScanState.verified);
    expect(rec.states.sublist(0, firstVerified),
        containsAllInOrder(<ScanState>[
          ScanState.scanning,
          ScanState.faceDetected,
          ScanState.matching,
        ]));
    c.dispose();
  });

  test('every camera picture is deleted', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(rig.capture.captures, greaterThan(0));
    expect(rig.capture.discarded, rig.capture.captures);
    c.dispose();
  });

  test('a different face is "unknown identity", never verified', () async {
    final Rig rig = Rig(embeddings: <Float32List>[vec(0, 0, 1, 0)]);
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    final Recorder rec = Recorder(c);
    await c.scan();
    expect(c.state, ScanState.unknown);
    expect(c.verifiedName, isNull);
    expect(rec.states, isNot(contains(ScanState.verified)));
    c.dispose();
  });

  test('no recognition model: unavailable, camera and sound untouched',
      () async {
    final Rig rig = Rig(manifest: testManifest(calibrated: false));
    await rig.loadSound();
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.modelUnavailable);
    expect(rig.capture.opens, 0);
    expect(rig.soundPlayer.starts, 0);
    c.dispose();
  });

  test('embedder that is not available: unavailable', () async {
    final Rig rig = Rig();
    rig.embedder.available = false;
    await rig.loadSound();
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.modelUnavailable);
    c.dispose();
  });

  test('camera denied: camera unavailable, no scanning sound', () async {
    final Rig rig = Rig();
    rig.capture.status = CameraStatus.permissionDenied;
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.cameraUnavailable);
    expect(rig.soundPlayer.starts, 0);
    c.dispose();
  });

  test('nobody enrolled: failed, not unknown', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.failed);
    expect(c.message, contains('enrolled'));
    expect(rig.soundPlayer.starts, 0);
    c.dispose();
  });

  test('a camera error ends the scan as failed and stops the sound', () async {
    final Rig rig = Rig();
    rig.capture.throwOnCapture = true;
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.failed);
    expect(rig.soundPlayer.playing, isFalse);
    c.dispose();
  });

  test('no face before the timeout: failed, sound stopped', () async {
    final Rig rig = Rig();
    rig.detector.script = <List<DetectedFace>>[<DetectedFace>[]];
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition(
      scanTimeout: const Duration(milliseconds: 150),
    );
    final Recorder rec = Recorder(c);
    await c.scan();
    expect(c.state, ScanState.failed);
    expect(c.message, contains('timed out'));
    expect(rec.states, isNot(contains(ScanState.verified)));
    expect(rig.soundPlayer.playing, isFalse);
    expect(rig.soundPlayer.starts, 1);
    expect(rig.capture.discarded, rig.capture.captures);
    c.dispose();
  });

  test('a poor face keeps scanning, then a good one matches', () async {
    final Rig rig = Rig();
    rig.detector.script = <List<DetectedFace>>[
      <DetectedFace>[],
      <DetectedFace>[goodFace(), goodFace()],
      <DetectedFace>[goodFace()],
    ];
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.verified);
    expect(rig.capture.captures, 3);
    c.dispose();
  });

  test('sound starts with the scan and stops at the end, exactly once',
      () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(rig.soundPlayer.starts, 1);
    expect(rig.soundPlayer.overlaps, 0);
    expect(rig.soundPlayer.playing, isFalse);
    c.dispose();
  });

  test('a muted app scans normally and plays nothing', () async {
    final Rig rig = Rig(soundEnabled: false);
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.verified);
    expect(rig.soundPlayer.starts, 0);
    c.dispose();
  });

  test('cancel stops the sound and never reports a result', () async {
    final Rig rig = Rig();
    rig.embedder.delay = const Duration(milliseconds: 200);
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    final Recorder rec = Recorder(c);
    final Future<void> scanning = c.scan();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await c.cancel();
    await scanning;
    expect(c.state, ScanState.ready);
    expect(rec.states, isNot(contains(ScanState.verified)));
    expect(rig.soundPlayer.playing, isFalse);
    c.dispose();
  });

  test('a second scan while one runs is ignored', () async {
    final Rig rig = Rig();
    rig.embedder.delay = const Duration(milliseconds: 100);
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    final Future<void> first = c.scan();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await c.scan();
    await first;
    expect(rig.soundPlayer.starts, 1);
    expect(rig.embedder.calls, 1);
    c.dispose();
  });

  test('going to the background cancels, silences and closes the camera',
      () async {
    final Rig rig = Rig();
    rig.embedder.delay = const Duration(milliseconds: 200);
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    final Future<void> scanning = c.scan();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await c.onBackground();
    await scanning;
    expect(rig.soundPlayer.playing, isFalse);
    expect(rig.capture.closes, greaterThan(0));
    expect(c.state, isNot(ScanState.verified));
    c.dispose();
  });

  test('the verified name is cleared after the result display time',
      () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition(
      resultVisible: const Duration(milliseconds: 50),
    );
    final Recorder rec = Recorder(c);
    await c.scan();
    expect(c.verifiedName, 'Amina');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.state, ScanState.ready);
    expect(c.verifiedName, isNull);
    expect(rec.violation, isFalse);
    c.dispose();
  });

  test('the sound result never changes the recognition result', () async {
    final Rig rig = Rig();
    rig.soundPlayer.throwOnStart = true;
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.verified);
    c.dispose();
  });

  test('unreadable vault: failed with a clear message', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.enrolOne('Amina', vec(1, 0, 0, 0));
    await rig.keys.delete();
    final FaceRecognitionController c = rig.recognition();
    await c.scan();
    expect(c.state, ScanState.failed);
    expect(c.message, contains('cannot be read'));
    c.dispose();
  });
}
