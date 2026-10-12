import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'avatar_animator.dart';
import 'avatar_pose.dart';

/// Draws the 2.5D humanoid avatar from an [AvatarPose].
///
/// Everything is vector drawing in a 100-unit coordinate space: no images,
/// no shaders created per frame, no blur filters and no `saveLayer`, so it
/// stays light on weak GPUs. The 2.5D feel comes from parallax: the visor,
/// eyes and mouth shift a little more than the shell when the head turns,
/// and the torso breathes.
class AvatarPainter extends CustomPainter {
  AvatarPainter({
    required this.animator,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final AvatarAnimator animator;

  /// Fewer glow rings and no ripples (set by the widget before each frame).
  bool lowPower = false;

  static const Color _shellLight = Color(0xFFEAF0FF);
  static const Color _shellDark = Color(0xFFAEBBE6);
  static const Color _visorTop = Color(0xFF0E1740);
  static const Color _visorBottom = Color(0xFF070B22);
  static const Rect _headRect = Rect.fromLTRB(15, 13, 85, 85);
  static const Rect _visorRect = Rect.fromLTRB(22, 28, 78, 72);
  static const Rect _torsoRect = Rect.fromLTRB(20, 88, 80, 125);
  static const List<Offset> _eyeCenters = <Offset>[
    Offset(37.5, 49),
    Offset(62.5, 49),
  ];

  static final RRect _head =
      RRect.fromRectAndRadius(_headRect, const Radius.circular(30));
  static final RRect _visor =
      RRect.fromRectAndRadius(_visorRect, const Radius.circular(20));
  static final RRect _torso = RRect.fromRectAndCorners(
    _torsoRect,
    topLeft: const Radius.circular(22),
    topRight: const Radius.circular(22),
  );

  // Gradients are created once (their colours never change with state).
  final Paint _shellPaint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[_shellLight, _shellDark],
    ).createShader(_headRect);
  final Paint _visorPaint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[_visorTop, _visorBottom],
    ).createShader(_visorRect);
  final Paint _torsoPaint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[Color(0xFF27357A), Color(0xFF121A45)],
    ).createShader(_torsoRect);

  /// One scratch paint reused for every flat colour (no per-frame allocation).
  final Paint _p = Paint();

  Paint _fill(Color color) => _p
    ..style = PaintingStyle.fill
    ..strokeWidth = 0
    ..shader = null
    ..color = color;

  Paint _stroke(Color color, double width) => _p
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..shader = null
    ..color = color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    final int depth = canvas.getSaveCount();
    try {
      canvas.clipRect(Offset.zero & size);
      canvas.scale(size.width / 100);
      _paintScene(canvas, animator.pose);
    } catch (_) {
      // A drawing bug must never crash the app: show a plain face instead.
      // (In debug builds the error is rethrown so tests and developers see it.)
      if (kDebugMode) rethrow;
      canvas.restoreToCount(depth);
      _paintFallback(canvas);
    } finally {
      canvas.restoreToCount(depth - 1);
    }
  }

  void _paintScene(Canvas canvas, AvatarPose p) {
    _paintAura(canvas, p);
    if (!lowPower && p.ripple > 0.02) _paintRipples(canvas, p);
    _paintBody(canvas, p);
    _paintHead(canvas, p);
    if (p.dots > 0.02) _paintThoughtDots(canvas, p);
  }

  void _paintAura(Canvas canvas, AvatarPose p) {
    final int rings = lowPower ? 3 : 5;
    final double alpha = (p.aura / rings).clamp(0.0, 1.0).toDouble();
    for (int i = 0; i < rings; i++) {
      final double radius = 52 * (1 - 0.6 * i / rings);
      canvas.drawCircle(
        const Offset(50, 48),
        radius,
        _fill(p.accent.withValues(alpha: alpha)),
      );
    }
  }

  void _paintRipples(Canvas canvas, AvatarPose p) {
    for (int i = 0; i < 2; i++) {
      final double phase = (p.time * 0.5 + i * 0.5) % 1.0;
      canvas.drawCircle(
        const Offset(50, 48),
        40 + phase * 14,
        _stroke(
          p.accent.withValues(alpha: (1 - phase) * 0.4 * p.ripple),
          0.8,
        ),
      );
    }
  }

  void _paintBody(Canvas canvas, AvatarPose p) {
    canvas.save();
    // Breathing: the chest swells slightly around the collar line.
    canvas.translate(50, 100);
    canvas.scale(1 + 0.014 * p.breath, 1 + 0.02 * p.breath);
    canvas.translate(-50, -100);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(42, 78, 58, 92),
        const Radius.circular(4),
      ),
      _fill(const Color(0xFF1B2656)),
    );
    canvas.drawRRect(_torso, _torsoPaint);
    canvas.drawRRect(_torso, _stroke(p.accent.withValues(alpha: 0.5), 0.7));
    canvas.drawCircle(
      const Offset(50, 102),
      6,
      _fill(p.accent.withValues(alpha: 0.18)),
    );
    canvas.drawCircle(const Offset(50, 102), 3.2, _fill(p.accent));
    canvas.restore();
  }

  void _paintHead(Canvas canvas, AvatarPose p) {
    final Color accent = p.accent;
    canvas.save();
    canvas.translate(50, 50 + p.headBob);
    canvas.rotate(p.headTilt);
    canvas.translate(-50, -50);

    // Antenna and orb.
    canvas.drawLine(
      const Offset(50, 14),
      const Offset(50, 7),
      _stroke(_shellDark, 1.2),
    );
    canvas.drawCircle(
      const Offset(50, 5.5),
      4,
      _fill(accent.withValues(alpha: 0.2 * p.orbAlpha)),
    );
    canvas.drawCircle(
      const Offset(50, 5.5),
      2.2,
      _fill(accent.withValues(alpha: p.orbAlpha)),
    );

    // Ear pods move slightly against the head turn (depth cue).
    canvas.save();
    canvas.translate(-p.headYaw * 0.8, 0);
    final RRect leftPod = RRect.fromRectAndRadius(
      const Rect.fromLTRB(8, 40, 17, 60),
      const Radius.circular(4.5),
    );
    final RRect rightPod = RRect.fromRectAndRadius(
      const Rect.fromLTRB(83, 40, 92, 60),
      const Radius.circular(4.5),
    );
    canvas.drawRRect(leftPod, _fill(_shellDark));
    canvas.drawRRect(rightPod, _fill(_shellDark));
    final Color podGlow = accent.withValues(alpha: p.podGlow);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(11.5, 45, 13.5, 55),
        const Radius.circular(1),
      ),
      _fill(podGlow),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(86.5, 45, 88.5, 55),
        const Radius.circular(1),
      ),
      _fill(podGlow),
    );
    canvas.restore();

    // Shell.
    canvas.drawRRect(_head.shift(const Offset(0, 1.5)), _fill(const Color(0x33000000)));
    canvas.drawRRect(_head, _shellPaint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(38, 18, 62, 20.2),
        const Radius.circular(1.1),
      ),
      _fill(accent.withValues(alpha: 0.85)),
    );

    // Visor group: shifts with the head turn for a 2.5D look.
    canvas.save();
    canvas.translate(p.headYaw * 1.2, 0);
    canvas.drawRRect(_visor, _visorPaint);
    canvas.drawRRect(_visor, _stroke(accent.withValues(alpha: 0.55), 0.9));

    canvas.translate(p.headYaw * 1.4, 0);
    final Color cheek = AlmusColors.purple.withValues(alpha: p.cheek);
    canvas.drawCircle(const Offset(30.5, 61), 3, _fill(cheek));
    canvas.drawCircle(const Offset(69.5, 61), 3, _fill(cheek));
    _paintEyes(canvas, p);
    _paintMouth(canvas, p);
    canvas.restore();

    canvas.restore();
  }

  void _paintEyes(Canvas canvas, AvatarPose p) {
    final Color accent = p.accent;
    final Offset gaze = Offset(p.gazeX * 2.4, p.gazeY * 1.8);
    final double openAlpha = 1 - math.max(p.crossEyes, p.happyEyes);

    for (final Offset base in _eyeCenters) {
      if (openAlpha > 0.02) {
        final Offset c = base + gaze;
        final double w = 10 * p.eyeScaleX;
        final double h = 12.8 * p.eyeScaleY * p.eyeOpen;
        final Rect eye = Rect.fromCenter(center: c, width: w, height: h);
        canvas.drawOval(
          eye.inflate(1.6),
          _fill(accent.withValues(alpha: 0.28 * openAlpha)),
        );
        canvas.drawOval(eye, _fill(accent.withValues(alpha: openAlpha)));
        canvas.drawOval(
          Rect.fromCenter(center: c, width: w * 0.55, height: h * 0.55),
          _fill(
            Color.lerp(accent, Colors.white, 0.7)!
                .withValues(alpha: openAlpha),
          ),
        );
        if (p.eyeOpen > 0.5) {
          canvas.drawCircle(
            c + const Offset(-1.6, -2),
            1.1,
            _fill(Colors.white.withValues(alpha: 0.9 * openAlpha)),
          );
        }
      }
      if (p.crossEyes > 0.02) {
        final Paint cross = _stroke(accent.withValues(alpha: p.crossEyes), 2.2);
        canvas.drawLine(base + const Offset(-4, -4), base + const Offset(4, 4), cross);
        canvas.drawLine(base + const Offset(-4, 4), base + const Offset(4, -4), cross);
      }
      if (p.happyEyes > 0.02) {
        final Path arc = Path()
          ..moveTo(base.dx - 4.5, base.dy + 2)
          ..quadraticBezierTo(base.dx, base.dy - 5, base.dx + 4.5, base.dy + 2);
        canvas.drawPath(arc, _stroke(accent.withValues(alpha: p.happyEyes), 2.2));
      }
    }
  }

  void _paintMouth(Canvas canvas, AvatarPose p) {
    final Color accent = p.accent;
    final double lineAlpha = (1 - p.mouthOpen * 5).clamp(0.0, 1.0).toDouble();
    if (lineAlpha > 0.02) {
      final double half = 6.5 + 2 * math.max(0.0, p.smile - 0.5);
      final double cornerY = 63.5 - 2.0 * p.smile;
      final double controlY = 63.5 + 3.4 * p.smile;
      final Path mouth = Path()
        ..moveTo(50 - half, cornerY + p.slant * 1.0)
        ..quadraticBezierTo(50, controlY, 50 + half, cornerY - p.slant * 1.5);
      canvas.drawPath(mouth, _stroke(accent.withValues(alpha: lineAlpha), 1.5));
    }
    if (p.mouthOpen > 0.04) {
      canvas.drawOval(
        Rect.fromCenter(
          center: const Offset(50, 63),
          width: 4.5 + 4.5 * p.mouthWidth,
          height: 1.8 + 6.8 * p.mouthOpen,
        ),
        _fill(accent.withValues(alpha: 0.9)),
      );
    }
  }

  void _paintThoughtDots(Canvas canvas, AvatarPose p) {
    const List<Offset> dots = <Offset>[
      Offset(88, 22),
      Offset(92, 15),
      Offset(96, 8),
    ];
    const List<double> radii = <double>[1.4, 1.8, 2.2];
    final int active = (p.time * 1.5).floor() % 3;
    for (int i = 0; i < dots.length; i++) {
      final double a = (i == active ? 1.0 : 0.3) * p.dots;
      canvas.drawCircle(dots[i], radii[i], _fill(p.accent.withValues(alpha: a)));
    }
  }

  /// Minimal face used only if normal drawing throws in a release build.
  void _paintFallback(Canvas canvas) {
    canvas.drawCircle(const Offset(50, 48), 36, _fill(_shellDark));
    canvas.drawCircle(const Offset(38, 44), 5, _fill(_visorBottom));
    canvas.drawCircle(const Offset(62, 44), 5, _fill(_visorBottom));
    canvas.drawLine(const Offset(42, 62), const Offset(58, 62), _stroke(_visorBottom, 2));
  }

  @override
  bool shouldRepaint(covariant AvatarPainter oldDelegate) =>
      oldDelegate.animator != animator;
}
