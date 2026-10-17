import 'dart:async';

import 'package:almus_ai/face/cloud/cloud_face_api.dart';
import 'package:almus_ai/face/cloud/cloud_face_controller.dart';
import 'package:almus_ai/face/cloud/cloud_face_storage.dart';
import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_ports.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_face_fakes.dart';
import 'face_fakes.dart';

void main() {
  group('verify', () {
    test('a "verified" answer shows the enrolled name and uploads exactly one photo', () async {
      final Setup t = Setup();
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.verified);
      expect(c.verifiedName, 'Musty');
      expect(t.api.calls.where((String x) => x.startsWith('verify')).toList(),
          <String>['verify:$kId']);
      expect(t.capture.discarded, t.capture.captures); // every camera file deleted
      expect(c.cameraOpen, isFalse);
      c.dispose();
    });

    test('"not verified" never shows a name', () async {
      final Setup t = Setup()..api.verifyResult = false;
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.notVerified);
      expect(c.verifiedName, isNull);
      c.dispose();
    });

    test('an error, timeout or odd answer is a failure, never a match', () async {
      for (final Object err in <Object>[
        const CloudFaceException('network', 'offline'),
        const CloudFaceException('invalid_response', 'odd'),
        StateError('boom'),
      ]) {
        final Setup t = Setup()..api.verifyError = err;
        final CloudFaceController c = t.controller();
        await c.refresh();
        await c.verify();
        expect(c.state, CloudScanState.failed, reason: '$err');
        expect(c.verifiedName, isNull);
        c.dispose();
      }
    });

    test('without consent nothing is captured or sent', () async {
      final Setup t = Setup(consent: false);
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.failed);
      expect(t.capture.opens, 0);
      expect(t.api.calls, isEmpty);
      c.dispose();
    });

    test('old consent wording no longer counts', () async {
      final Setup t = Setup(consent: false);
      t.consentStore.value = CloudFaceConsent(
          version: kCloudFaceConsentVersion - 1, grantedAt: DateTime.utc(2025, 1, 1));
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(c.hasConsent, isFalse);
      await c.verify();
      expect(t.api.calls, isEmpty);
      c.dispose();
    });

    test('nobody enrolled: nothing is sent', () async {
      final Setup t = Setup(enrolled: false);
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.failed);
      expect(t.api.calls, isEmpty);
      c.dispose();
    });

    test('backend not configured: camera is not even opened', () async {
      final Setup t = Setup(settings: const AppSettings());
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.failed);
      expect(t.capture.opens, 0);
      c.dispose();
    });

    test('no face or several faces: no photo is uploaded', () async {
      for (final List<DetectedFace> faces in <List<DetectedFace>>[
        <DetectedFace>[],
        <DetectedFace>[goodFace(), goodFace()],
      ]) {
        final Setup t = Setup();
        t.detector.script = <List<DetectedFace>>[faces];
        final CloudFaceController c = t.controller(timeout: const Duration(milliseconds: 80));
        await c.refresh();
        await c.verify();
        expect(c.state, CloudScanState.failed);
        expect(t.api.calls, isEmpty);
        expect(t.capture.discarded, t.capture.captures);
        c.dispose();
      }
    });

    test('camera unavailable', () async {
      final Setup t = Setup();
      t.capture.status = CameraStatus.permissionDenied;
      final CloudFaceController c = t.controller();
      await c.refresh();
      await c.verify();
      expect(c.state, CloudScanState.cameraUnavailable);
      expect(t.api.calls, isEmpty);
      c.dispose();
    });

    test('cancelling during the upload ignores a late "verified"', () async {
      final Setup t = Setup();
      t.api.verifyGate = Completer<bool>();
      final CloudFaceController c = t.controller();
      await c.refresh();
      final Future<void> run = c.verify();
      while (c.state != CloudScanState.uploading) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await c.cancel();
      t.api.verifyGate!.complete(true);
      await run;
      expect(c.state, isNot(CloudScanState.verified));
      expect(c.verifiedName, isNull);
      c.dispose();
    });
  });

  group('enroll', () {
    test('uploads 3 photos, keeps only name and id, closes the camera', () async {
      final Setup t = Setup(enrolled: false);
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('  Musty  '), isTrue);
      expect(t.api.calls, <String>['enroll', 'addPhoto', 'addPhoto']);
      expect(t.links.value!.name, 'Musty');
      expect(t.links.value!.personId, kId);
      expect(c.cameraOpen, isFalse);
      expect(t.capture.discarded, t.capture.captures);
      c.dispose();
    });

    test('needs consent and a valid name', () async {
      final Setup t = Setup(consent: false, enrolled: false);
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isFalse);
      expect(t.api.calls, isEmpty);
      await c.grantConsent();
      expect(await c.enroll('   '), isFalse);
      expect(await c.enroll('x' * 41), isFalse);
      expect(t.api.calls, isEmpty);
      c.dispose();
    });

    test('re-enrolling deletes the old person first and links the new one', () async {
      final Setup t = Setup();
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isTrue);
      expect(t.api.calls.first, 'remove:$kId');
      expect(t.links.value!.personId, kId);
      c.dispose();
    });

    test('if the old person cannot be deleted, nothing changes and nothing new is created', () async {
      final Setup t = Setup()..api.removeError = const CloudFaceException('network', 'offline');
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isFalse);
      expect(t.api.calls, <String>['remove:$kId']);
      expect(t.links.value!.personId, kId);
      expect(t.capture.opens, 0);
      c.dispose();
    });

    test('a failed extra photo still enrols, and says so', () async {
      final Setup t = Setup(enrolled: false)
        ..api.addPhotoError = const CloudFaceException('face_not_usable', 'bad');
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isTrue);
      expect(c.message, contains('1 of 3'));
      c.dispose();
    });

    test('a failed first upload leaves nothing stored', () async {
      final Setup t = Setup(enrolled: false)
        ..api.enrollError = const CloudFaceException('face_not_usable', 'bad');
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isFalse);
      expect(t.links.value, isNull);
      expect(c.state, CloudScanState.failed);
      c.dispose();
    });

    test('if this phone cannot save the link, the new cloud face is deleted again', () async {
      final Setup t = Setup(enrolled: false);
      t.links.failWrites = true;
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.enroll('Musty'), isFalse);
      expect(t.api.removed, <String>[kId]);
      c.dispose();
    });
  });

  group('deleting', () {
    test('delete removes the cloud face, then the local link', () async {
      final Setup t = Setup();
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.deleteCloudFace(), isTrue);
      expect(t.api.removed, <String>[kId]);
      expect(t.links.value, isNull);
      expect(c.link, isNull);
      c.dispose();
    });

    test('a failed cloud delete is NOT reported as done and keeps the link for a retry', () async {
      final Setup t = Setup()..api.removeError = const CloudFaceException('network', 'offline');
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.deleteCloudFace(), isFalse);
      expect(c.state, CloudScanState.failed);
      expect(c.message, startsWith('NOT deleted'));
      expect(t.links.value, isNotNull);
      c.dispose();
    });

    test('withdrawing consent clears consent only after a successful delete', () async {
      final Setup t = Setup()..api.removeError = const CloudFaceException('network', 'offline');
      final CloudFaceController c = t.controller();
      await c.refresh();
      expect(await c.withdrawConsent(), isFalse);
      expect(c.hasConsent, isTrue);
      t.api.removeError = null;
      expect(await c.withdrawConsent(), isTrue);
      expect(c.hasConsent, isFalse);
      expect(t.links.value, isNull);
      c.dispose();
    });
  });
}
