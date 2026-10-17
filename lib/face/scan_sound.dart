import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Longest a scan sound may ever play, whatever else happens.
const Duration kMaxScanSound = Duration(seconds: 15);

abstract class ScanSoundPlayer {
  Future<void> startLoop();
  Future<void> stop();
  Future<void> dispose();
}

/// Plays the bundled, original `assets/audio/scan_loop.wav` in a loop.
class AudioplayersScanSoundPlayer implements ScanSoundPlayer {
  AudioPlayer? _player;

  AudioPlayer get _p => _player ??= AudioPlayer();

  @override
  Future<void> startLoop() async {
    await _p.setReleaseMode(ReleaseMode.loop);
    await _p.setVolume(0.4);
    await _p.play(AssetSource('audio/scan_loop.wav'));
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }

  @override
  Future<void> dispose() async {
    final AudioPlayer? p = _player;
    _player = null;
    await p?.dispose();
  }
}

abstract class ScanSoundSettingsStore {
  Future<bool> loadEnabled();
  Future<void> saveEnabled(bool value);
}

class PrefsScanSoundSettingsStore implements ScanSoundSettingsStore {
  const PrefsScanSoundSettingsStore();

  static const String _key = 'face_scan_sound_enabled';

  @override
  Future<bool> loadEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  @override
  Future<void> saveEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_key, value);
}

class MemoryScanSoundSettingsStore implements ScanSoundSettingsStore {
  MemoryScanSoundSettingsStore({this.enabled = false});

  bool enabled;

  @override
  Future<bool> loadEnabled() async => enabled;

  @override
  Future<void> saveEnabled(bool value) async => enabled = value;
}

/// Feedback sound for a scan. It is decoration only: whether a sound played,
/// failed or was muted never changes the result of a scan.
///
/// - starts only when [start] is called (the controller calls it when a scan
///   really begins);
/// - never plays twice at once;
/// - stops on [stop], when muted, when the app leaves the foreground, and
///   after [maxDuration] at the latest.
/// Off by default (opt in); the setting is stored in [store].
class ScanSoundController extends ChangeNotifier {
  ScanSoundController({
    required ScanSoundPlayer player,
    required ScanSoundSettingsStore store,
    this.maxDuration = kMaxScanSound,
  })  : _player = player,
        _store = store;

  final ScanSoundPlayer _player;
  final ScanSoundSettingsStore _store;
  final Duration maxDuration;

  bool _enabled = false;
  bool _playing = false;
  int _generation = 0;
  Timer? _cap;

  bool get enabled => _enabled;
  bool get isPlaying => _playing;

  Future<void> load() async {
    try {
      _enabled = await _store.loadEnabled();
    } on Object {
      _enabled = false;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!value) await stop();
    notifyListeners();
    try {
      await _store.saveEnabled(value);
    } on Object {
      // The switch still works for this session.
    }
  }

  Future<void> start() async {
    if (!_enabled || _playing) return;
    _playing = true;
    final int token = ++_generation;
    _cap?.cancel();
    _cap = Timer(maxDuration, () {
      stop();
    });
    try {
      await _player.startLoop();
    } on Object {
      if (token == _generation) {
        _playing = false;
        _cap?.cancel();
      }
      return;
    }
    // stop() may have been called while the player was starting.
    if (token != _generation && !_playing) {
      await _safeStop();
    }
  }

  Future<void> stop() async {
    _generation++;
    _cap?.cancel();
    _cap = null;
    if (!_playing) return;
    _playing = false;
    await _safeStop();
  }

  Future<void> _safeStop() async {
    try {
      await _player.stop();
    } on Object {
      // Nothing to do; the sound is only feedback.
    }
  }

  /// Call from the screen's lifecycle observer.
  void onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      stop();
    }
  }

  @override
  void dispose() {
    _cap?.cancel();
    _generation++;
    _playing = false;
    _player.stop().catchError((Object _) {});
    _player.dispose().catchError((Object _) {});
    super.dispose();
  }
}
