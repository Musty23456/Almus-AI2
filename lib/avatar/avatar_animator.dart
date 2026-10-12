import 'dart:math' as math;
import 'dart:ui' show Color;

import '../models/robot_state.dart';
import 'avatar_pose.dart';
import 'avatar_profile.dart';
import 'avatar_targets.dart';

/// Turns "which state are we in" plus elapsed time into an [AvatarPose].
///
/// Pure Dart logic with no drawing, so it is cheap and easy to unit test.
/// Every value eases toward the current state's target with an exponential
/// filter, so switching state never pops. On top of that it adds:
/// random blinking (with occasional double blinks), eye glances, head sway,
/// breathing and a talking mouth.
class AvatarAnimator {
  AvatarAnimator({
    AvatarProfile? profile,
    math.Random? random,
    RobotState initial = RobotState.idle,
  })  : profile = profile ?? AvatarProfile.current,
        _random = random ?? math.Random(),
        _state = initial,
        pose = AvatarPose(accent: AvatarTarget.of(initial).accent) {
    snap();
    _blinkTimer = _nextBlinkDelay(AvatarTarget.of(initial).blinkRate);
  }

  final AvatarProfile profile;
  final math.Random _random;
  final AvatarPose pose;

  /// Optional real mouth level (0..1), e.g. from speech playback loudness.
  /// When null the talking mouth is animated procedurally.
  double? mouthLevelOverride;

  RobotState _state;
  double _time = 0;
  double _talkTime = 0;
  double _swayPhase = 0;
  double _bobPhase = 0;
  double _breathPhase = 0;

  // Smoothed (not directly exposed) values.
  double _swayAmp = 0.012;
  double _swayHz = 0.15;
  double _tiltStatic = 0;
  double _bobAmp = 1.4;
  double _bobHz = 0.25;
  double _breathAmp = 1;
  double _auraBase = 0.2;
  double _auraHz = 0.25;

  double _blinkTimer = 3;
  double _blinkProgress = -1;
  static const double _blinkSeconds = 0.16;

  double _gazeTx = 0;
  double _gazeTy = 0;
  double _saccadeTimer = 0;

  RobotState get state => _state;

  /// True while an eye blink is in progress.
  bool get isBlinking => _blinkProgress >= 0;

  /// Switches state. The pose eases toward it on the next [update] calls.
  void setState(RobotState next) {
    if (next == _state) return;
    _state = next;
    _saccadeTimer = 0;
    if (next == RobotState.talking) _talkTime = 0;
  }

  /// Jumps straight to the current state without easing (first frame,
  /// "reduce motion", tests).
  void snap() {
    final AvatarTarget tg = AvatarTarget.of(_state);
    _blend(tg, 1);
    _gazeTx = 0;
    _gazeTy = 0;
    pose
      ..gazeX = 0
      ..gazeY = 0
      ..eyeOpen = 1
      ..mouthOpen = tg.mouthOpen
      ..orbAlpha = 1;
    _blinkProgress = -1;
  }

  /// Advances the animation by [seconds] (clamped to 0.1 so a slow frame
  /// never makes the avatar jump).
  void update(double seconds) {
    final double dt = seconds.isNaN ? 0.0 : seconds.clamp(0.0, 0.1).toDouble();
    if (dt <= 0) return;
    _time += dt;
    if (_state == RobotState.talking) _talkTime += dt;

    final AvatarTarget tg = AvatarTarget.of(_state);
    final double k = 1 - math.exp(-profile.transitionSpeed * dt);
    _blend(tg, k);
    _updateBlink(dt, tg);
    _updateGaze(dt, tg);
    _updateMotion(dt);
    _updateMouth(dt, tg);
    _updateLights(tg, k);
    pose.time = _time;
  }

  // ------------------------------------------------------------ internals

  static double _approach(double current, double target, double k) =>
      current + (target - current) * k;

  void _blend(AvatarTarget tg, double k) {
    final AvatarPose p = pose;
    p.accent = Color.lerp(p.accent, tg.accent, k)!;
    p.eyeScaleX = _approach(p.eyeScaleX, tg.eyeScaleX, k);
    p.eyeScaleY = _approach(p.eyeScaleY, tg.eyeScaleY, k);
    p.smile = _approach(p.smile, tg.smile, k);
    p.slant = _approach(p.slant, tg.slant, k);
    p.mouthWidth = _approach(p.mouthWidth, tg.mouthWidth, k);
    p.ripple = _approach(p.ripple, tg.ripple, k);
    p.dots = _approach(p.dots, tg.dots, k);
    p.crossEyes = _approach(p.crossEyes, tg.crossEyes, k);
    p.happyEyes = _approach(p.happyEyes, tg.happyEyes, k);
    p.cheek = _approach(p.cheek, tg.cheek, k);
    _swayAmp = _approach(_swayAmp, tg.swayAmp, k);
    _swayHz = _approach(_swayHz, tg.swayHz, k);
    _tiltStatic = _approach(_tiltStatic, tg.tiltStatic, k);
    _bobAmp = _approach(_bobAmp, tg.bobAmp, k);
    _bobHz = _approach(_bobHz, tg.bobHz, k);
    _breathAmp = _approach(_breathAmp, tg.breathAmp, k);
    _auraBase = _approach(_auraBase, tg.aura, k);
    _auraHz = _approach(_auraHz, tg.auraHz, k);
  }

  double _nextBlinkDelay(double rate) {
    final double r = rate <= 0 ? 1 : rate;
    final double span = profile.blinkMaxSeconds - profile.blinkMinSeconds;
    return (profile.blinkMinSeconds + _random.nextDouble() * span) / r;
  }

  void _updateBlink(double dt, AvatarTarget tg) {
    if (_blinkProgress >= 0) {
      _blinkProgress += dt / _blinkSeconds;
      if (_blinkProgress >= 1) {
        _blinkProgress = -1;
        pose.eyeOpen = 1;
        _blinkTimer = _random.nextDouble() < profile.doubleBlinkChance
            ? 0.14
            : _nextBlinkDelay(tg.blinkRate);
      } else {
        pose.eyeOpen = 1 - 0.92 * math.sin(math.pi * _blinkProgress);
      }
      return;
    }
    pose.eyeOpen = 1;
    if (tg.blinkRate <= 0) return;
    _blinkTimer -= dt;
    if (_blinkTimer <= 0) _blinkProgress = 0;
  }

  void _updateGaze(double dt, AvatarTarget tg) {
    switch (tg.gaze) {
      case GazeMode.scan:
        _gazeTx = math.sin(_time * 2.4) * 0.9;
        _gazeTy = -0.65;
      case GazeMode.steady:
        _gazeTx = 0;
        _gazeTy = 0;
      case GazeMode.attentive:
      case GazeMode.wander:
        _saccadeTimer -= dt;
        if (_saccadeTimer <= 0) {
          final double range = tg.gazeRange * profile.gazeWander;
          _gazeTx = (_random.nextDouble() * 2 - 1) * range;
          _gazeTy = (_random.nextDouble() * 2 - 1) * range * 0.6;
          _saccadeTimer = (tg.gaze == GazeMode.attentive ? 2.0 : 1.2) +
              _random.nextDouble() * 2.2;
        }
    }
    final double gk =
        1 - math.exp(-(tg.gaze == GazeMode.scan ? 10.0 : 16.0) * dt);
    pose.gazeX = _approach(pose.gazeX, _gazeTx, gk);
    pose.gazeY = _approach(pose.gazeY, _gazeTy, gk);
  }

  void _updateMotion(double dt) {
    final double m = profile.motionScale;
    _swayPhase += 2 * math.pi * _swayHz * dt;
    _bobPhase += 2 * math.pi * _bobHz * (4.0 / profile.breathSeconds) * dt;
    _breathPhase += 2 * math.pi * dt / profile.breathSeconds;
    pose.headTilt = (_tiltStatic + math.sin(_swayPhase) * _swayAmp) * m;
    pose.headBob = math.sin(_bobPhase) * _bobAmp * m;
    final double yaw = pose.gazeX * 0.35 + math.sin(_time * 0.37) * 0.18;
    pose.headYaw = yaw.clamp(-1.0, 1.0).toDouble() * m;
    pose.breath = (0.5 + 0.5 * math.sin(_breathPhase)) * _breathAmp * m;
  }

  void _updateMouth(double dt, AvatarTarget tg) {
    double target = tg.mouthOpen;
    if (tg.talking) {
      final double? external = mouthLevelOverride;
      if (external != null && !external.isNaN) {
        target = external.clamp(0.0, 1.0).toDouble();
      } else {
        final double syllable =
            0.5 + 0.5 * math.sin(2 * math.pi * 3.1 * _talkTime);
        final double envelope =
            0.65 + 0.35 * math.sin(2 * math.pi * 1.25 * _talkTime).abs();
        // Short pause between "phrases" so it looks like real speech.
        final double phrase = (_talkTime % 3.6) < 3.1 ? 1.0 : 0.0;
        target = syllable * envelope * phrase;
      }
    }
    final double mk = 1 - math.exp(-(tg.talking ? 26.0 : 12.0) * dt);
    pose.mouthOpen = _approach(pose.mouthOpen, target, mk);
  }

  void _updateLights(AvatarTarget tg, double k) {
    // Pulse uses real time so it is independent of frame rate.
    final double pulse = 0.5 + 0.5 * math.sin(2 * math.pi * _auraHz * _time);
    pose.aura = _auraBase + 0.1 * pulse;

    final double podTarget = tg.talking
        ? 0.55 + 0.45 * math.sin(2 * math.pi * 1.5 * _time)
        : 0.75;
    pose.podGlow = _approach(pose.podGlow, podTarget, math.min(1.0, k * 2));

    switch (_state) {
      case RobotState.thinking:
        pose.orbAlpha = 0.5 + 0.5 * math.sin(2 * math.pi * 0.75 * _time);
      case RobotState.error:
        pose.orbAlpha = ((_time * 1.5) % 1.0) < 0.5 ? 1.0 : 0.25;
      case RobotState.idle:
      case RobotState.listening:
      case RobotState.talking:
      case RobotState.happy:
        pose.orbAlpha = 1;
    }
  }
}
