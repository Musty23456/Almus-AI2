import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../avatar/avatar_animator.dart';
import '../avatar/avatar_painter.dart';
import '../avatar/avatar_profile.dart';
import '../models/robot_state.dart';

/// Animated humanoid robot avatar (Phase 5: 2.5D, vector drawn, no assets
/// required).
///
/// One [Ticker] drives an [AvatarAnimator]; the painter repaints only when
/// the animator produced a new frame, at a capped frame rate. With the
/// system "reduce motion" setting on, the avatar is drawn still and only
/// changes when the state changes.
class RobotAvatar extends StatefulWidget {
  const RobotAvatar({
    super.key,
    required this.state,
    this.size = 240,
    this.mouthLevel,
    this.profile,
    this.lowPower,
  });

  final RobotState state;
  final double size;

  /// Optional real mouth level (0..1) for TALKING, e.g. from audio loudness.
  /// When null (or its value is null) the mouth is animated procedurally.
  final ValueListenable<double?>? mouthLevel;

  /// Tuning override. Defaults to [AvatarProfile.current].
  final AvatarProfile? profile;

  /// Forces low-power mode on or off. Null follows [AvatarRuntime.lowPower].
  final bool? lowPower;

  @override
  State<RobotAvatar> createState() => _RobotAvatarState();
}

class _FrameNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _RobotAvatarState extends State<RobotAvatar>
    with SingleTickerProviderStateMixin {
  late final AvatarAnimator _animator;
  late final AvatarPainter _painter;
  late final Ticker _ticker;
  final _FrameNotifier _frame = _FrameNotifier();

  Duration _last = Duration.zero;
  double _accumulated = 0;
  bool _reduceMotion = false;

  bool get _lowPower => widget.lowPower ?? AvatarRuntime.lowPower.value;

  double get _frameInterval {
    int fps = _animator.profile.maxFps;
    if (_lowPower) fps = math.min(fps, 20);
    if (widget.size < 80) fps = math.min(fps, 24);
    return 1.0 / fps;
  }

  @override
  void initState() {
    super.initState();
    _animator = AvatarAnimator(
      profile: widget.profile ?? AvatarProfile.current,
      initial: widget.state,
    );
    _painter = AvatarPainter(animator: _animator, repaint: _frame);
    _painter.lowPower = _lowPower;
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant RobotAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _animator.setState(widget.state);
    }
    _painter.lowPower = _lowPower;
    if (_reduceMotion) {
      _animator.snap();
      _frame.bump();
    }
  }

  void _syncTicker() {
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _animator.setState(widget.state);
      _animator.snap();
      _frame.bump();
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _accumulated = 0;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    _accumulated += (elapsed - _last).inMicroseconds / 1000000.0;
    _last = elapsed;
    if (_accumulated < _frameInterval) return;
    _animator.mouthLevelOverride = widget.mouthLevel?.value;
    _animator.update(_accumulated);
    _accumulated = 0;
    _painter.lowPower = _lowPower;
    AvatarRuntime.paintedFrames++;
    _frame.bump();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Almus robot avatar. State: ${widget.state.label}',
      child: SizedBox(
        width: widget.size,
        height: widget.size * 1.1,
        child: RepaintBoundary(
          child: CustomPaint(painter: _painter),
        ),
      ),
    );
  }
}
