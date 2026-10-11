import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/robot_state.dart';
import '../theme/app_theme.dart';

/// Lightweight animated humanoid robot, drawn entirely in code
/// (no external assets). One repeating controller drives every state.
class RobotAvatar extends StatefulWidget {
  const RobotAvatar({super.key, required this.state, this.size = 240});

  final RobotState state;
  final double size;

  @override
  State<RobotAvatar> createState() => _RobotAvatarState();
}

class _RobotAvatarState extends State<RobotAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system "reduce motion" setting and save battery.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
          child: CustomPaint(
            painter: _RobotPainter(
              animation: _controller,
              state: widget.state,
            ),
          ),
        ),
      ),
    );
  }
}

class _RobotPainter extends CustomPainter {
  _RobotPainter({required this.animation, required this.state})
      : super(repaint: animation);

  final Animation<double> animation;
  final RobotState state;

  static const Color _shellLight = Color(0xFFEAF0FF);
  static const Color _shellDark = Color(0xFFAEBBE6);
  static const Color _visorTop = Color(0xFF0E1740);
  static const Color _visorBottom = Color(0xFF070B22);
  static const double _tau = 2 * math.pi;
  static const List<Offset> _eyeCenters = <Offset>[
    Offset(37.5, 49),
    Offset(62.5, 49),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final double t = animation.value;
    final Color accent = AlmusColors.forState(state);

    canvas.clipRect(Offset.zero & size);
    canvas.save();
    canvas.scale(size.width / 100);

    _paintAura(canvas, accent, t);
    if (state == RobotState.listening) {
      _paintRipples(canvas, accent, t);
    }
    _paintBody(canvas, accent);

    final double bob =
        math.sin(_tau * t) * (state == RobotState.talking ? 0.9 : 1.4);
    final double tilt =
        state == RobotState.thinking ? math.sin(_tau * t) * 0.045 : 0.0;
    canvas.save();
    canvas.translate(50, 50 + bob);
    canvas.rotate(tilt);
    canvas.translate(-50, -50);
    _paintHead(canvas, accent, t);
    canvas.restore();

    if (state == RobotState.thinking) {
      _paintThoughtDots(canvas, accent, t);
    }
    canvas.restore();
  }

  void _paintAura(Canvas canvas, Color accent, double t) {
    final double speed = state == RobotState.talking ? 4 : 1;
    final double pulse = 0.5 + 0.5 * math.sin(_tau * t * speed);
    const Offset center = Offset(50, 48);
    final Rect rect = Rect.fromCircle(center: center, radius: 52);
    final Paint paint = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          accent.withValues(alpha: 0.18 + 0.12 * pulse),
          accent.withValues(alpha: 0),
        ],
      ).createShader(rect);
    canvas.drawCircle(center, 52, paint);
  }

  void _paintRipples(Canvas canvas, Color accent, double t) {
    for (int i = 0; i < 2; i++) {
      final double phase = (t * 2 + i * 0.5) % 1.0;
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = accent.withValues(alpha: (1 - phase) * 0.4);
      canvas.drawCircle(const Offset(50, 48), 40 + phase * 14, paint);
    }
  }

  void _paintBody(Canvas canvas, Color accent) {
    final RRect neck = RRect.fromRectAndRadius(
      const Rect.fromLTRB(42, 78, 58, 92),
      const Radius.circular(4),
    );
    canvas.drawRRect(neck, Paint()..color = const Color(0xFF1B2656));

    const Rect torsoRect = Rect.fromLTRB(20, 88, 80, 125);
    final RRect torso = RRect.fromRectAndCorners(
      torsoRect,
      topLeft: const Radius.circular(22),
      topRight: const Radius.circular(22),
    );
    canvas.drawRRect(
      torso,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF27357A), Color(0xFF121A45)],
        ).createShader(torsoRect),
    );
    canvas.drawRRect(
      torso,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = accent.withValues(alpha: 0.5),
    );
    canvas.drawCircle(
      const Offset(50, 102),
      6,
      Paint()..color = accent.withValues(alpha: 0.18),
    );
    canvas.drawCircle(const Offset(50, 102), 3.2, Paint()..color = accent);
  }

  void _paintHead(Canvas canvas, Color accent, double t) {
    // Antenna.
    canvas.drawLine(
      const Offset(50, 14),
      const Offset(50, 7),
      Paint()
        ..color = _shellDark
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
    );
    double orbAlpha = 1.0;
    if (state == RobotState.thinking) {
      orbAlpha = 0.5 + 0.5 * math.sin(_tau * t * 3);
    } else if (state == RobotState.error) {
      orbAlpha = ((t * 6) % 1.0) < 0.5 ? 1.0 : 0.25;
    }
    canvas.drawCircle(
      const Offset(50, 5.5),
      4,
      Paint()..color = accent.withValues(alpha: 0.2 * orbAlpha),
    );
    canvas.drawCircle(
      const Offset(50, 5.5),
      2.2,
      Paint()..color = accent.withValues(alpha: orbAlpha),
    );

    // Ear pods.
    final Paint podPaint = Paint()..color = _shellDark;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(8, 40, 17, 60),
        const Radius.circular(4.5),
      ),
      podPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(83, 40, 92, 60),
        const Radius.circular(4.5),
      ),
      podPaint,
    );
    final double podPulse = state == RobotState.talking
        ? 0.55 + 0.45 * math.sin(_tau * t * 6)
        : 0.75;
    final Paint podGlow = Paint()..color = accent.withValues(alpha: podPulse);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(11.5, 45, 13.5, 55),
        const Radius.circular(1),
      ),
      podGlow,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(86.5, 45, 88.5, 55),
        const Radius.circular(1),
      ),
      podGlow,
    );

    // Shell.
    const Rect headRect = Rect.fromLTRB(15, 13, 85, 85);
    final RRect head =
        RRect.fromRectAndRadius(headRect, const Radius.circular(30));
    canvas.drawRRect(
      head.shift(const Offset(0, 1.5)),
      Paint()..color = const Color(0x33000000),
    );
    canvas.drawRRect(
      head,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[_shellLight, _shellDark],
        ).createShader(headRect),
    );

    // Forehead light strip.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(38, 18, 62, 20.2),
        const Radius.circular(1.1),
      ),
      Paint()..color = accent.withValues(alpha: 0.85),
    );

    // Visor.
    const Rect visorRect = Rect.fromLTRB(22, 28, 78, 72);
    final RRect visor =
        RRect.fromRectAndRadius(visorRect, const Radius.circular(20));
    canvas.drawRRect(
      visor,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_visorTop, _visorBottom],
        ).createShader(visorRect),
    );
    canvas.drawRRect(
      visor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = accent.withValues(alpha: 0.55),
    );

    // Cheeks for a friendlier look.
    final Paint cheek = Paint()
      ..color = AlmusColors.purple.withValues(alpha: 0.28);
    canvas.drawCircle(const Offset(30.5, 61), 3, cheek);
    canvas.drawCircle(const Offset(69.5, 61), 3, cheek);

    _paintEyes(canvas, accent, t);
    _paintMouth(canvas, accent, t);
  }

  void _paintEyes(Canvas canvas, Color accent, double t) {
    if (state == RobotState.error) {
      final Paint cross = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      for (final Offset c in _eyeCenters) {
        canvas.drawLine(c + const Offset(-4, -4), c + const Offset(4, 4), cross);
        canvas.drawLine(c + const Offset(-4, 4), c + const Offset(4, -4), cross);
      }
      return;
    }

    double rx = 5.0;
    double ry = 6.4;
    double dx = 0;
    double dy = 0;
    if (state == RobotState.listening) {
      rx = 5.6;
      ry = 7.6;
    } else if (state == RobotState.thinking) {
      ry = 5.6;
      dx = math.sin(_tau * t * 2) * 2.4;
      dy = -1.6;
    } else if (state == RobotState.talking) {
      ry = 6.0 + 0.6 * math.sin(_tau * t * 8);
    }

    double blink = 1.0;
    if (state != RobotState.thinking && t > 0.88 && t < 0.94) {
      blink = math.max(0.12, 1 - math.sin(math.pi * (t - 0.88) / 0.06));
    }

    final Color inner = Color.lerp(accent, Colors.white, 0.7)!;
    for (final Offset c in _eyeCenters) {
      final Offset center = c + Offset(dx, dy);
      final Rect eye = Rect.fromCenter(
        center: center,
        width: rx * 2,
        height: ry * 2 * blink,
      );
      canvas.drawOval(
        eye.inflate(1.6),
        Paint()
          ..color = accent.withValues(alpha: 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
      );
      canvas.drawOval(
        eye,
        Paint()
          ..shader = RadialGradient(colors: <Color>[inner, accent])
              .createShader(eye),
      );
      if (blink > 0.5) {
        canvas.drawCircle(
          center + const Offset(-1.6, -2),
          1.1,
          Paint()..color = Colors.white.withValues(alpha: 0.9),
        );
      }
    }
  }

  void _paintMouth(Canvas canvas, Color accent, double t) {
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = accent;

    switch (state) {
      case RobotState.idle:
        canvas.drawPath(
          Path()
            ..moveTo(43.5, 61.5)
            ..quadraticBezierTo(50, 66.5, 56.5, 61.5),
          line,
        );
      case RobotState.listening:
        canvas.drawOval(
          Rect.fromCenter(center: const Offset(50, 63), width: 5, height: 4.4),
          line,
        );
      case RobotState.thinking:
        canvas.drawLine(const Offset(45.5, 63.5), const Offset(54.5, 62), line);
      case RobotState.talking:
        final double open = (0.5 + 0.5 * math.sin(_tau * t * 12)) *
            (0.65 + 0.35 * math.sin(_tau * t * 5).abs());
        canvas.drawOval(
          Rect.fromCenter(
            center: const Offset(50, 63),
            width: 9,
            height: 1.8 + 6.8 * open,
          ),
          Paint()..color = accent.withValues(alpha: 0.9),
        );
      case RobotState.error:
        canvas.drawPath(
          Path()
            ..moveTo(43.5, 65.5)
            ..quadraticBezierTo(50, 60.5, 56.5, 65.5),
          line,
        );
    }
  }

  void _paintThoughtDots(Canvas canvas, Color accent, double t) {
    const List<Offset> dots = <Offset>[
      Offset(88, 22),
      Offset(92, 15),
      Offset(96, 8),
    ];
    const List<double> radii = <double>[1.4, 1.8, 2.2];
    final int active = (t * 6).floor() % 3;
    for (int i = 0; i < dots.length; i++) {
      canvas.drawCircle(
        dots[i],
        radii[i],
        Paint()..color = accent.withValues(alpha: i == active ? 1.0 : 0.3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RobotPainter oldDelegate) =>
      oldDelegate.state != state;
}
