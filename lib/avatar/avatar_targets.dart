import 'dart:ui' show Color;

import '../models/robot_state.dart';
import '../theme/app_theme.dart';

/// How the eyes behave in a state.
enum GazeMode {
  /// Looks around with small random glances.
  wander,

  /// Looks at the user, with tiny glances (listening).
  attentive,

  /// Eyes sweep side to side, looking up (thinking).
  scan,

  /// Looks straight ahead.
  steady,
}

/// The "resting values" of one avatar state. The animator eases the live
/// pose toward these numbers, which is what makes transitions smooth.
class AvatarTarget {
  const AvatarTarget({
    required this.accent,
    this.eyeScaleX = 1,
    this.eyeScaleY = 1,
    this.smile = 0.5,
    this.slant = 0,
    this.mouthOpen = 0,
    this.mouthWidth = 1,
    this.tiltStatic = 0,
    this.swayAmp = 0.012,
    this.swayHz = 0.15,
    this.bobAmp = 1.4,
    this.bobHz = 0.25,
    this.breathAmp = 1,
    this.aura = 0.2,
    this.auraHz = 0.25,
    this.ripple = 0,
    this.dots = 0,
    this.crossEyes = 0,
    this.happyEyes = 0,
    this.cheek = 0.28,
    this.blinkRate = 1,
    this.gaze = GazeMode.wander,
    this.gazeRange = 0.5,
    this.talking = false,
  });

  final Color accent;
  final double eyeScaleX;
  final double eyeScaleY;
  final double smile;
  final double slant;
  final double mouthOpen;
  final double mouthWidth;

  /// Constant head roll (radians) plus a sway of [swayAmp] at [swayHz].
  final double tiltStatic;
  final double swayAmp;
  final double swayHz;

  /// Vertical head bob (units) at [bobHz].
  final double bobAmp;
  final double bobHz;
  final double breathAmp;

  final double aura;
  final double auraHz;
  final double ripple;
  final double dots;
  final double crossEyes;
  final double happyEyes;
  final double cheek;

  /// 0 disables blinking; 1 is the normal rate.
  final double blinkRate;
  final GazeMode gaze;
  final double gazeRange;

  /// True when the mouth is driven by the talking animation.
  final bool talking;

  static AvatarTarget of(RobotState state) {
    return switch (state) {
      RobotState.idle => const AvatarTarget(accent: AlmusColors.cyan),
      RobotState.listening => const AvatarTarget(
          accent: AlmusColors.blue,
          eyeScaleX: 1.12,
          eyeScaleY: 1.2,
          smile: 0,
          mouthOpen: 0.38,
          mouthWidth: 0.1,
          tiltStatic: 0.05,
          swayAmp: 0.01,
          bobAmp: 1.0,
          aura: 0.26,
          ripple: 1,
          blinkRate: 0.8,
          gaze: GazeMode.attentive,
          gazeRange: 0.12,
        ),
      RobotState.thinking => const AvatarTarget(
          accent: AlmusColors.purple,
          eyeScaleY: 0.88,
          smile: 0,
          slant: 1,
          swayAmp: 0.045,
          swayHz: 0.4,
          bobAmp: 1.2,
          auraHz: 0.75,
          dots: 1,
          blinkRate: 0.35,
          gaze: GazeMode.scan,
        ),
      RobotState.talking => const AvatarTarget(
          accent: AlmusColors.mint,
          eyeScaleY: 0.94,
          smile: 0.45,
          swayAmp: 0.02,
          swayHz: 0.5,
          bobAmp: 0.9,
          bobHz: 0.5,
          aura: 0.3,
          auraHz: 1,
          blinkRate: 0.8,
          gazeRange: 0.25,
          talking: true,
        ),
      RobotState.happy => const AvatarTarget(
          accent: AlmusColors.amber,
          smile: 1,
          swayAmp: 0.035,
          swayHz: 1.2,
          bobAmp: 2.0,
          bobHz: 1.6,
          breathAmp: 1.2,
          aura: 0.3,
          auraHz: 0.8,
          happyEyes: 1,
          cheek: 0.55,
          blinkRate: 0,
          gaze: GazeMode.steady,
        ),
      RobotState.error => const AvatarTarget(
          accent: AlmusColors.error,
          smile: -0.8,
          swayAmp: 0.02,
          swayHz: 5,
          bobAmp: 0,
          breathAmp: 0.3,
          aura: 0.25,
          auraHz: 1.5,
          crossEyes: 1,
          blinkRate: 0,
          gaze: GazeMode.steady,
        ),
    };
  }
}
