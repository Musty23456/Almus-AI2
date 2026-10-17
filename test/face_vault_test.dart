import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:almus_ai/face/face_consent.dart';
import 'package:almus_ai/face/face_matcher.dart';
import 'package:almus_ai/face/face_model_locator.dart';
import 'package:almus_ai/face/face_models.dart';
import 'package:almus_ai/face/face_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'face_fakes.dart';

List<EnrolledIdentity> sample() => <EnrolledIdentity>[
      EnrolledIdentity(
        id: 'abc',
        displayName: 'Zainab Example',
        createdAt: DateTime.utc(2026, 5, 1, 12),
        samples: <FaceEmbedding>[emb(vec(1, 2, 3, 4)), emb(vec(4, 3, 2, 1))],
      ),
    ];

void main() {
  late MemoryVaultFile file;
  late MemoryVaultKeyStore keys;
  late FaceTemplateVault vault;

  setUp(() {
    file = MemoryVaultFile();
    keys = MemoryVaultKeyStore();
    vault = FaceTemplateVault(file: file, keys: keys);
  });

  test('an empty vault loads as empty, not as an error', () async {
    final VaultContents c = await vault.load();
    expect(c.identities, isEmpty);
    expect(c.unreadable, isFalse);
  });

  test('saves and loads templates unchanged', () async {
    await vault.save('test-model-1', sample());
    final VaultContents c = await vault.load();
    expect(c.unreadable, isFalse);
    expect(c.modelId, 'test-model-1');
    expect(c.identities.single.displayName, 'Zainab Example');
    expect(c.identities.single.samples, hasLength(2));
    final double self = c.identities.single.samples.first
        .similarity(emb(vec(1, 2, 3, 4)));
    expect(self, closeTo(1.0, 1e-5));
  });

  test('the file on disk is not readable plain text', () async {
    await vault.save('test-model-1', sample());
    final Uint8List raw = file.bytes!;
    final String asText = latin1.decode(raw);
    expect(asText.contains('Zainab'), isFalse);
    expect(asText.contains('identities'), isFalse);
    expect(asText.contains('test-model-1'), isFalse);
  });

  test('two saves use different nonces', () async {
    await vault.save('test-model-1', sample());
    final Uint8List a = Uint8List.fromList(file.bytes!);
    await vault.save('test-model-1', sample());
    expect(file.bytes, isNot(equals(a)));
  });

  test('a tampered file is reported unreadable, not half-loaded', () async {
    await vault.save('test-model-1', sample());
    file.bytes![file.bytes!.length ~/ 2] ^= 0x01;
    final VaultContents c = await vault.load();
    expect(c.unreadable, isTrue);
    expect(c.identities, isEmpty);
  });

  test('a truncated or foreign file is unreadable', () async {
    await file.write(Uint8List.fromList(<int>[1, 2, 3]));
    expect((await vault.load()).unreadable, isTrue);
    await file.write(Uint8List(100));
    expect((await vault.load()).unreadable, isTrue);
  });

  test('without the key the file cannot be read', () async {
    await vault.save('test-model-1', sample());
    await keys.delete();
    expect((await vault.load()).unreadable, isTrue);
  });

  test('deleteAll removes the file and the key (crypto-erase)', () async {
    await vault.save('test-model-1', sample());
    final Uint8List copy = Uint8List.fromList(file.bytes!);
    expect(await vault.deleteAll(), isTrue);
    expect(await file.exists(), isFalse);
    expect(await keys.read(), isNull);
    // A surviving copy of the old file is useless: the key is gone and a new
    // key is random.
    final MemoryVaultFile other = MemoryVaultFile()..bytes = copy;
    final FaceTemplateVault v2 = FaceTemplateVault(file: other, keys: keys);
    expect((await v2.load()).unreadable, isTrue);
    await keys.readOrCreate();
    expect((await v2.load()).unreadable, isTrue);
  });

  test('deleteAll on an empty vault succeeds', () async {
    expect(await vault.deleteAll(), isTrue);
  });

  group('consent', () {
    test('only the current wording counts', () {
      expect(
        FaceConsent(version: kFaceConsentVersion, grantedAt: DateTime.now())
            .isCurrent,
        isTrue,
      );
      expect(
        FaceConsent(version: kFaceConsentVersion + 1, grantedAt: DateTime.now())
            .isCurrent,
        isFalse,
      );
    });

    test('the consent text says what is stored and what is not', () {
      expect(kFaceConsentText, contains('not photographs'));
      expect(kFaceConsentText, contains('deleted'));
      expect(kFaceConsentText, contains('Nothing is uploaded'));
      expect(kFaceConsentText, contains('fooled'));
    });

    test('prefs store round-trips and clears', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const PrefsFaceConsentStore s = PrefsFaceConsentStore();
      expect(await s.read(), isNull);
      await s.write(FaceConsent(
          version: kFaceConsentVersion, grantedAt: DateTime.utc(2026, 1, 2)));
      expect((await s.read())!.version, kFaceConsentVersion);
      await s.clear();
      expect(await s.read(), isNull);
    });
  });

  group('legacy Phase 9 face photo', () {
    test('is deleted together with its preference', () async {
      final Directory dir = await Directory.systemTemp.createTemp('almus_face');
      addTearDown(() => dir.delete(recursive: true));
      final File photo = File('${dir.path}/almus_face_sample.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      SharedPreferences.setMockInitialValues(
          <String, Object>{'phase9_face_enrollment_path': photo.path});
      final bool removed =
          await const LegacyFaceSamplePurger().purge(supportDirectory: dir);
      expect(removed, isTrue);
      expect(photo.existsSync(), isFalse);
      final SharedPreferences p = await SharedPreferences.getInstance();
      expect(p.getString('phase9_face_enrollment_path'), isNull);
    });

    test('does nothing when there is nothing to remove', () async {
      final Directory dir = await Directory.systemTemp.createTemp('almus_face');
      addTearDown(() => dir.delete(recursive: true));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        await const LegacyFaceSamplePurger().purge(supportDirectory: dir),
        isFalse,
      );
    });
  });

  group('model locator', () {
    test('reports "not installed" when there is no manifest', () async {
      final Directory dir = await Directory.systemTemp.createTemp('almus_model');
      addTearDown(() => dir.delete(recursive: true));
      final FaceModelCheck c = await FaceModelLocator(dir).check();
      expect(c.status, FaceModelStatus.notInstalled);
    });

    test('rejects a model whose checksum does not match', () async {
      final Directory dir = await Directory.systemTemp.createTemp('almus_model');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/model.tflite').writeAsBytesSync(<int>[9, 9, 9]);
      File('${dir.path}/manifest.json').writeAsStringSync(
        '{"model_id":"m","sha256":"${'c' * 64}","license":"L","license_url":"u",'
        '"training_data_note":"n","input_size":112,"embedding_dimension":128,'
        '"input_mean":127.5,"input_std":127.5,'
        '"eyes":{"left":[38.3,51.7],"right":[73.5,51.5]}}',
      );
      final FaceModelCheck c = await FaceModelLocator(dir).check();
      expect(c.status, FaceModelStatus.hashMismatch);
    });

    test('a matching but uncalibrated model is still not usable', () async {
      final Directory dir = await Directory.systemTemp.createTemp('almus_model');
      addTearDown(() => dir.delete(recursive: true));
      final List<int> bytes = <int>[1, 2, 3, 4];
      File('${dir.path}/model.tflite').writeAsBytesSync(bytes);
      // sha256 of bytes 01 02 03 04
      const String sha =
          '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';
      File('${dir.path}/manifest.json').writeAsStringSync(
        '{"model_id":"m","sha256":"$sha","license":"L","license_url":"u",'
        '"training_data_note":"n","input_size":112,"embedding_dimension":128,'
        '"input_mean":127.5,"input_std":127.5,'
        '"eyes":{"left":[38.3,51.7],"right":[73.5,51.5]}}',
      );
      final FaceModelCheck c = await FaceModelLocator(dir).check();
      expect(c.status, FaceModelStatus.notCalibrated);
    });
  });
}
