import 'dart:convert';
import 'package:almus_ai/avatar/avatar_profile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _StringBundle extends AssetBundle {
  _StringBundle(this.text);
  final String? text;

  @override
  Future<ByteData> load(String key) async {
    final String? t = text;
    if (t == null) throw StateError('missing asset $key');
    final Uint8List bytes = Uint8List.fromList(utf8.encode(t));
    return ByteData.sublistView(bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AvatarProfile.current = AvatarProfile.defaults;
    AvatarProfile.loadedFromAsset = false;
  });

  test('fromJson clamps out-of-range values and ignores wrong types', () {
    final AvatarProfile p = AvatarProfile.fromJson(<String, Object?>{
      'blinkMinSeconds': 'fast',
      'blinkMaxSeconds': 9999,
      'transitionSpeed': -5,
      'maxFps': 500,
      'motionScale': double.nan,
    });
    expect(p.blinkMinSeconds, AvatarProfile.defaults.blinkMinSeconds);
    expect(p.blinkMaxSeconds, 20);
    expect(p.transitionSpeed, 2);
    expect(p.maxFps, 60);
    expect(p.motionScale, 1);
  });

  test('fromJson with a non-map gives the defaults', () {
    expect(AvatarProfile.fromJson('nope').maxFps, 30);
    expect(AvatarProfile.fromJson(null).breathSeconds, 4);
  });

  test('blink max is never below blink min', () {
    final AvatarProfile p = AvatarProfile.fromJson(
      <String, Object?>{'blinkMinSeconds': 6, 'blinkMaxSeconds': 2},
    );
    expect(p.blinkMaxSeconds, greaterThanOrEqualTo(p.blinkMinSeconds));
  });

  test('preload reads a valid bundle', () async {
    await AvatarProfile.preload(
      bundle: _StringBundle('{"maxFps": 24, "gazeWander": 0.5}'),
    );
    expect(AvatarProfile.current.maxFps, 24);
    expect(AvatarProfile.current.gazeWander, 0.5);
    expect(AvatarProfile.loadedFromAsset, isTrue);
  });

  test('preload falls back to defaults when the asset is missing', () async {
    await AvatarProfile.preload(bundle: _StringBundle(null));
    expect(AvatarProfile.current.maxFps, 30);
    expect(AvatarProfile.loadedFromAsset, isFalse);
  });

  test('preload falls back to defaults on broken JSON', () async {
    await AvatarProfile.preload(bundle: _StringBundle('{not json'));
    expect(AvatarProfile.loadedFromAsset, isFalse);
    expect(AvatarProfile.current.maxFps, 30);
  });

  test('the bundled avatar_profile.json is present and valid', () async {
    await AvatarProfile.preload();
    expect(AvatarProfile.loadedFromAsset, isTrue);
    expect(AvatarProfile.current.maxFps, inInclusiveRange(10, 60));
  });
}
