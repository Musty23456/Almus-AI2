import 'package:almus_ai/face/scan_sound.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

Future<void> pause([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('is silent unless the user turned it on', () async {
    final FakeSoundPlayer p = FakeSoundPlayer();
    final ScanSoundController c = makeSound(player: p, enabled: false);
    await c.load();
    await c.start();
    expect(p.starts, 0);
    expect(c.isPlaying, isFalse);
  });

  test('starts once and never overlaps itself', () async {
    final FakeSoundPlayer p = FakeSoundPlayer()
      ..startDelay = const Duration(milliseconds: 30);
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    await Future.wait(<Future<void>>[c.start(), c.start(), c.start()]);
    expect(p.starts, 1);
    expect(p.overlaps, 0);
    await c.stop();
    expect(p.playing, isFalse);
  });

  test('stop silences it and a second stop is harmless', () async {
    final FakeSoundPlayer p = FakeSoundPlayer();
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    await c.start();
    expect(c.isPlaying, isTrue);
    await c.stop();
    await c.stop();
    expect(c.isPlaying, isFalse);
    expect(p.playing, isFalse);
  });

  test('a stop that arrives while the player is starting still wins', () async {
    final FakeSoundPlayer p = FakeSoundPlayer()
      ..startDelay = const Duration(milliseconds: 40);
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    final Future<void> starting = c.start();
    await pause(5);
    await c.stop();
    await starting;
    expect(p.playing, isFalse);
    expect(c.isPlaying, isFalse);
  });

  test('never plays longer than the maximum duration', () async {
    final FakeSoundPlayer p = FakeSoundPlayer();
    final ScanSoundController c =
        makeSound(player: p, maxDuration: const Duration(milliseconds: 40));
    await c.load();
    await c.start();
    expect(p.playing, isTrue);
    await pause(150);
    expect(p.playing, isFalse);
    expect(c.isPlaying, isFalse);
  });

  test('muting while playing stops it immediately', () async {
    final FakeSoundPlayer p = FakeSoundPlayer();
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    await c.start();
    await c.setEnabled(false);
    expect(p.playing, isFalse);
    await c.start();
    expect(p.starts, 1);
  });

  test('leaving the foreground stops it', () async {
    final FakeSoundPlayer p = FakeSoundPlayer();
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    await c.start();
    c.onLifecycle(AppLifecycleState.paused);
    await pause(20);
    expect(p.playing, isFalse);
  });

  test('a broken audio player never throws into the scan', () async {
    final FakeSoundPlayer p = FakeSoundPlayer()..throwOnStart = true;
    final ScanSoundController c = makeSound(player: p);
    await c.load();
    await c.start();
    expect(c.isPlaying, isFalse);
  });

  test('the setting is remembered', () async {
    final MemoryScanSoundSettingsStore store = MemoryScanSoundSettingsStore();
    final ScanSoundController a =
        ScanSoundController(player: FakeSoundPlayer(), store: store);
    await a.setEnabled(true);
    final ScanSoundController b =
        ScanSoundController(player: FakeSoundPlayer(), store: store);
    await b.load();
    expect(b.enabled, isTrue);
  });
}
