import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tuning values for the avatar animation.
///
/// They can be overridden by the small local asset
/// `assets/avatar/avatar_profile.json`. If that file is missing, unreadable
/// or has bad values the app silently uses [defaults]: the avatar never
/// depends on the asset to work.
@immutable
class AvatarProfile {
  const AvatarProfile({
    this.blinkMinSeconds = 2.4,
    this.blinkMaxSeconds = 5.6,
    this.doubleBlinkChance = 0.12,
    this.transitionSpeed = 9.0,
    this.breathSeconds = 4.0,
    this.gazeWander = 1.0,
    this.motionScale = 1.0,
    this.maxFps = 30,
  });

  static const String assetPath = 'assets/avatar/avatar_profile.json';
  static const AvatarProfile defaults = AvatarProfile();

  /// Profile used by every avatar. Replaced once by [preload].
  static AvatarProfile current = defaults;

  /// Whether [current] came from the asset (true) or the built-in defaults.
  static bool loadedFromAsset = false;

  final double blinkMinSeconds;
  final double blinkMaxSeconds;
  final double doubleBlinkChance;

  /// How fast values move toward a new state (higher = snappier).
  final double transitionSpeed;
  final double breathSeconds;

  /// Multiplier for how far the eyes wander when idle.
  final double gazeWander;

  /// Multiplier for head / body motion. 0 gives a still avatar.
  final double motionScale;

  /// Cap on animation updates per second.
  final int maxFps;

  /// Reads values from decoded JSON. Anything missing or invalid falls back
  /// to the default for that field and is clamped to a safe range.
  factory AvatarProfile.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final Map<dynamic, dynamic> map = json;
    double read(String key, double fallback, double min, double max) {
      final Object? v = map[key];
      if (v is! num || v.isNaN || v.isInfinite) return fallback;
      return v.toDouble().clamp(min, max).toDouble();
    }

    final double blinkMin = read('blinkMinSeconds', 2.4, 0.8, 15);
    final double blinkMax = read('blinkMaxSeconds', 5.6, 0.8, 20);
    return AvatarProfile(
      blinkMinSeconds: blinkMin,
      blinkMaxSeconds: blinkMax < blinkMin ? blinkMin : blinkMax,
      doubleBlinkChance: read('doubleBlinkChance', 0.12, 0, 0.6),
      transitionSpeed: read('transitionSpeed', 9, 2, 30),
      breathSeconds: read('breathSeconds', 4, 2, 10),
      gazeWander: read('gazeWander', 1, 0, 2),
      motionScale: read('motionScale', 1, 0, 1.5),
      maxFps: read('maxFps', 30, 10, 60).round(),
    );
  }

  /// Loads the profile asset once. Never throws: on any problem the defaults
  /// stay in place and [loadedFromAsset] is false.
  static Future<AvatarProfile> preload({AssetBundle? bundle}) async {
    try {
      final String raw = await (bundle ?? rootBundle).loadString(assetPath);
      current = AvatarProfile.fromJson(jsonDecode(raw));
      loadedFromAsset = true;
    } on Object catch (_) {
      current = defaults;
      loadedFromAsset = false;
    }
    return current;
  }
}

/// Runtime switches and counters for the avatar (used by the Avatar Lab).
class AvatarRuntime {
  const AvatarRuntime._();

  /// Lower frame rate and fewer effects (saves battery on weak phones).
  static final ValueNotifier<bool> lowPower = ValueNotifier<bool>(false);

  /// Total number of avatar frames painted since the app started.
  static int paintedFrames = 0;
}
