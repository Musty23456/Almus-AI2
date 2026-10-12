import 'dart:math' as math;

import 'package:almus_ai/avatar/avatar_animator.dart';
import 'package:almus_ai/avatar/avatar_pose.dart';
import 'package:almus_ai/avatar/avatar_profile.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:flutter_test/flutter_test.dart';

AvatarAnimator _make({
  RobotState state = RobotState.idle,
  AvatarProfile profile = AvatarProfile.defaults,
}) =>
    AvatarAnimator(profile: profile, random: math.Random(7), initial: state);

void _run(AvatarAnimator a, double seconds, {double step = 1 / 30}) {
  for (double t = 0; t < seconds; t += step) {
    a.update(step);
  }
}

bool _finite(AvatarPose p) => <double>[
      p.eyeScaleX, p.eyeScaleY, p.eyeOpen, p.gazeX, p.gazeY, p.headTilt,
      p.headYaw, p.headBob, p.breath, p.smile, p.slant, p.mouthOpen,
      p.mouthWidth, p.aura, p.ripple, p.dots, p.crossEyes, p.happyEyes,
      p.cheek, p.podGlow, p.orbAlpha, p.time,
    ].every((double v) => v.isFinite);

void main() {
  test('every state produces finite, in-range values for a long run', () {
    final AvatarAnimator a = _make();
    for (final RobotState s in RobotState.values) {
      a.setState(s);
      _run(a, 5);
      expect(_finite(a.pose), isTrue, reason: s.name);
      expect(a.pose.eyeOpen, inInclusiveRange(0.0, 1.0));
      expect(a.pose.mouthOpen, inInclusiveRange(-0.01, 1.01));
      expect(a.pose.gazeX.abs(), lessThanOrEqualTo(1.0));
    }
  });

  test('transitions are smooth, not instant', () {
    final AvatarAnimator a = _make();
    a.setState(RobotState.error);
    a.update(1 / 30);
    expect(a.pose.crossEyes, greaterThan(0));
    expect(a.pose.crossEyes, lessThan(0.6));
    _run(a, 2);
    expect(a.pose.crossEyes, greaterThan(0.98));
  });

  test('idle blinks naturally and eyes reopen', () {
    final AvatarAnimator a = _make();
    int blinks = 0;
    bool was = false;
    double minOpen = 1;
    for (int i = 0; i < 30 * 30; i++) {
      a.update(1 / 30);
      if (a.isBlinking && !was) blinks++;
      was = a.isBlinking;
      minOpen = math.min(minOpen, a.pose.eyeOpen);
    }
    expect(blinks, greaterThanOrEqualTo(4));
    expect(minOpen, lessThan(0.3));
    expect(a.pose.eyeOpen, greaterThan(0.5));
  });

  test('error and happy states do not blink', () {
    for (final RobotState s in <RobotState>[RobotState.error, RobotState.happy]) {
      final AvatarAnimator a = _make(state: s);
      _run(a, 20);
      expect(a.isBlinking, isFalse, reason: s.name);
      expect(a.pose.eyeOpen, 1);
    }
  });

  test('talking opens and closes the mouth, others stay closed', () {
    final AvatarAnimator talk = _make(state: RobotState.talking);
    double maxOpen = 0;
    double sum = 0;
    int n = 0;
    for (int i = 0; i < 30 * 6; i++) {
      talk.update(1 / 30);
      maxOpen = math.max(maxOpen, talk.pose.mouthOpen);
      sum += talk.pose.mouthOpen;
      n++;
    }
    expect(maxOpen, greaterThan(0.5));
    expect(sum / n, greaterThan(0.1));

    final AvatarAnimator idle = _make();
    _run(idle, 3);
    expect(idle.pose.mouthOpen, lessThan(0.01));
  });

  test('mouthLevelOverride drives the talking mouth', () {
    final AvatarAnimator a = _make(state: RobotState.talking);
    a.mouthLevelOverride = 0.8;
    _run(a, 1);
    expect(a.pose.mouthOpen, closeTo(0.8, 0.05));
    a.mouthLevelOverride = 0;
    _run(a, 1);
    expect(a.pose.mouthOpen, lessThan(0.05));
  });

  test('thinking looks up and shows thought dots', () {
    final AvatarAnimator a = _make(state: RobotState.thinking);
    _run(a, 2);
    expect(a.pose.gazeY, lessThan(-0.4));
    expect(a.pose.dots, greaterThan(0.9));
  });

  test('listening shows ripples and happy shows smiling eyes', () {
    final AvatarAnimator l = _make(state: RobotState.listening);
    _run(l, 2);
    expect(l.pose.ripple, greaterThan(0.9));
    final AvatarAnimator h = _make(state: RobotState.happy);
    _run(h, 2);
    expect(h.pose.happyEyes, greaterThan(0.9));
    expect(h.pose.smile, greaterThan(0.9));
  });

  test('motionScale 0 keeps the head still', () {
    final AvatarAnimator a =
        _make(profile: const AvatarProfile(motionScale: 0));
    _run(a, 3);
    expect(a.pose.headBob, 0);
    expect(a.pose.headTilt, 0);
    expect(a.pose.breath, 0);
  });

  test('breathing moves over time', () {
    final AvatarAnimator a = _make();
    double min = 9, max = -9;
    for (int i = 0; i < 30 * 5; i++) {
      a.update(1 / 30);
      min = math.min(min, a.pose.breath);
      max = math.max(max, a.pose.breath);
    }
    expect(max - min, greaterThan(0.5));
  });

  test('huge or invalid time steps never break the pose', () {
    final AvatarAnimator a = _make();
    a.update(10);
    a.update(double.nan);
    a.update(-1);
    expect(_finite(a.pose), isTrue);
  });

  test('snap jumps to the state without easing', () {
    final AvatarAnimator a = _make();
    a.setState(RobotState.error);
    a.snap();
    expect(a.pose.crossEyes, 1);
    expect(a.pose.dots, 0);
  });
}
