import 'dart:typed_data';

import 'package:almus_ai/face/face_consent.dart';
import 'package:almus_ai/face/face_enrollment_controller.dart';
import 'package:almus_ai/face/face_matcher.dart';
import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_vault.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

FaceEnrollmentController makeEnroll(Rig rig, {int sampleCount = 3}) =>
    FaceEnrollmentController(
      runtime: rig.runtime,
      capture: rig.capture,
      decoder: rig.decoder,
      detector: rig.detector,
      vault: rig.vault,
      consentStore: rig.consent,
      sound: rig.sound,
      sampleCount: sampleCount,
      attemptPause: const Duration(milliseconds: 5),
      captureTimeout: const Duration(seconds: 2),
    );

void main() {
  test('nothing is captured or stored before consent', () async {
    final Rig rig = Rig();
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    expect(c.hasConsent, isFalse);
    expect(await c.enroll('Amina'), isFalse);
    expect(c.state, EnrollState.failed);
    expect(rig.capture.opens, 0);
    expect((await rig.vault.load()).identities, isEmpty);
    expect(await rig.vaultFile.exists(), isFalse);
    c.dispose();
  });

  test('an outdated consent does not count', () async {
    final Rig rig = Rig();
    rig.consent.value = FaceConsent(
        version: kFaceConsentVersion - 1, grantedAt: DateTime.utc(2025));
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    expect(c.hasConsent, isFalse);
    c.dispose();
  });

  test('enrols after consent, keeps templates only, deletes every picture',
      () async {
    final Rig rig = Rig(embeddings: <Float32List>[
      vec(1, 0, 0, 0),
      vec(0.95, 0.1, 0, 0),
      vec(0.97, 0, 0.1, 0),
    ]);
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    await c.grantConsent();
    expect(c.hasConsent, isTrue);
    expect(await c.enroll('Amina'), isTrue);
    expect(c.state, EnrollState.done);
    final VaultContents v = await rig.vault.load();
    expect(v.identities.single.displayName, 'Amina');
    expect(v.identities.single.samples, hasLength(3));
    expect(rig.capture.discarded, rig.capture.captures);
    expect(rig.capture.closes, greaterThan(0));
    expect(rig.soundPlayer.playing, isFalse);
    c.dispose();
  });

  test('enrolling the same name again replaces it', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 2);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('Amina'), isTrue);
    final String firstId = (await rig.vault.load()).identities.single.id;
    expect(await c.enroll('Amina'), isTrue);
    final VaultContents v = await rig.vault.load();
    expect(v.identities, hasLength(1));
    expect(v.identities.single.id, isNot(firstId));
    c.dispose();
  });

  test('two different people cannot be enrolled under one name', () async {
    final Rig rig = Rig(embeddings: <Float32List>[
      vec(1, 0, 0, 0),
      vec(0, 1, 0, 0),
    ]);
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('Amina'), isFalse);
    expect(c.state, EnrollState.failed);
    expect((await rig.vault.load()).identities, isEmpty);
    c.dispose();
  });

  test('a cancelled re-enrolment leaves the old data untouched', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('Amina'), isTrue);
    final String oldId = (await rig.vault.load()).identities.single.id;

    rig.embedder.delay = const Duration(milliseconds: 150);
    final Future<bool> second = c.enroll('Amina');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    c.cancel();
    expect(await second, isFalse);
    final VaultContents v = await rig.vault.load();
    expect(v.identities.single.id, oldId);
    expect(v.identities.single.samples, hasLength(3));
    c.dispose();
  });

  test('delete all removes templates and the key', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 1);
    await c.refresh();
    await c.grantConsent();
    await c.enroll('Amina');
    expect(c.identities, hasLength(1));
    expect(await c.deleteAll(), isTrue);
    expect(c.identities, isEmpty);
    expect(await rig.vaultFile.exists(), isFalse);
    expect(await rig.keys.read(), isNull);
    c.dispose();
  });

  test('deleting one person keeps the others', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 1);
    await c.refresh();
    await c.grantConsent();
    await c.enroll('Amina');
    await c.enroll('Bala');
    expect(c.identities, hasLength(2));
    final String aminaId =
        c.identities.firstWhere((EnrolledIdentity e) => e.displayName == 'Amina').id;
    await c.deleteIdentity(aminaId);
    final VaultContents v = await rig.vault.load();
    expect(v.identities.single.displayName, 'Bala');
    c.dispose();
  });

  test('withdrawing consent deletes everything and blocks enrolment', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 1);
    await c.refresh();
    await c.grantConsent();
    await c.enroll('Amina');
    expect(await c.withdrawConsent(), isTrue);
    expect(c.hasConsent, isFalse);
    expect(rig.consent.value, isNull);
    expect(await rig.vaultFile.exists(), isFalse);
    expect(await c.enroll('Amina'), isFalse);
    c.dispose();
  });

  test('templates made with another model are replaced, not mixed', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    await rig.vault.save('old-model', <EnrolledIdentity>[
      EnrolledIdentity(
        id: 'old',
        displayName: 'Old',
        createdAt: DateTime.utc(2025),
        samples: <FaceEmbedding>[emb(vec(1, 0, 0, 0), modelId: 'old-model')],
      ),
    ]);
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 1);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('Amina'), isTrue);
    final VaultContents v = await rig.vault.load();
    expect(v.modelId, 'test-model-1');
    expect(v.identities.map((EnrolledIdentity e) => e.displayName),
        <String>['Amina']);
    c.dispose();
  });

  test('rejects empty and over-long names', () async {
    final Rig rig = Rig();
    final FaceEnrollmentController c = makeEnroll(rig);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('   '), isFalse);
    expect(await c.enroll('x' * 41), isFalse);
    expect(rig.capture.opens, 0);
    c.dispose();
  });

  test('a bad picture is retried; a camera failure stops enrolment', () async {
    final Rig rig = Rig();
    await rig.loadSound();
    rig.detector.script = <List<DetectedFace>>[
      <DetectedFace>[],
      <DetectedFace>[goodFace()],
    ];
    final FaceEnrollmentController c = makeEnroll(rig, sampleCount: 1);
    await c.refresh();
    await c.grantConsent();
    expect(await c.enroll('Amina'), isTrue);
    expect(rig.capture.captures, 2);

    rig.capture.throwOnCapture = true;
    expect(await c.enroll('Bala'), isFalse);
    expect(c.state, EnrollState.failed);
    c.dispose();
  });
}
