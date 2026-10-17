import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Visual states of [BiometricEyeScanner].
///
/// This widget is decoration only. It draws a futuristic eye and scan
/// effects, and it can never unlock anything: access is decided solely by
/// Android's biometric prompt (see AppLockController).
enum EyeScannerState { idle, scanning, verified, failed, locked }

/// A stylised animated eye with scanning rings, a sweeping beam and a few
/// particles, drawn with one [CustomPaint] and one [AnimationController].
///
/// Cost control: the heavy glow (blur) is only used while scanning, the
/// animation runs slowly otherwise, and with the system "reduce motion"
/// setting the picture is static.
class BiometricEyeScanner extends StatefulWidget {
  const BiometricEyeScanner({
    super.key,
    required this.state,
    this.maxSize = 300,
    this.semanticLabel,
  });

  final EyeScannerState state;

  /// The widget is square and never larger than this (or its parent).
  final double maxSize;

  final String? semanticLabel;

  /// Accent colour used for each state.
  static Color colorFor(EyeScannerState state) {
    return switch (state) {
      EyeScannerState.idle => AlmusColors.cyan,
      EyeScannerState.scanning => AlmusColors.cyan,
      EyeScannerState.verified => AlmusColors.mint,
      EyeScannerState.failed => AlmusColors.error,
      EyeScannerState.locked => AlmusColors.purple,
    };
  }

  @override
  State<BiometricEyeScanner> createState() => _BiometricEyeScannerState();
}

class _BiometricEyeScannerState extends State<BiometricEyeScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _periodFor(widget.state),
  );
  bool _reduceMotion = false;

  static Duration _periodFor(EyeScannerState s) {
    return s == EyeScannerState.scanning
        ? const Duration(milliseconds: 2200)
        : const Duration(seconds: 6);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(BiometricEyeScanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _sync();
  }

  void _sync() {
    _controller.duration = _periodFor(widget.state);
    if (_reduceMotion) {
      _controller
        ..stop()
        ..value = 0.25;
    } else {
      // (Re)start with the period of the current state.
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
    final Color target = BiometricEyeScanner.colorFor(widget.state);
    return Semantics(
      label: widget.semanticLabel ?? 'Biometric scanner',
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double available = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : widget.maxSize;
          final double side = math.min(widget.maxSize, available);
          return SizedBox.square(
            dimension: side,
            child: RepaintBoundary(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: target),
                duration: const Duration(milliseconds: 350),
                builder: (BuildContext context, Color? color, Widget? _) {
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (BuildContext context, Widget? _) {
                      return CustomPaint(
                        painter: _EyePainter(
                          t: _controller.value,
                          state: widget.state,
                          color: color ?? target,
                          reduceMotion: _reduceMotion,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  _EyePainter({
    required this.t,
    required this.state,
    required this.color,
    required this.reduceMotion,
  });

  final double t;
  final EyeScannerState state;
  final Color color;
  final bool reduceMotion;

  static const int _fibers = 32;
  static const int _particles = 12;

  bool get _scanning => state == EyeScannerState.scanning;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    final Offset c = Offset(s / 2, s / 2);
    final double tau = 2 * math.pi;
    final double spin = t * tau;

    _background(canvas, c, s);
    _rings(canvas, c, s, spin);
    _hudBrackets(canvas, s);
    _eye(canvas, c, s);
    if (_scanning) _beam(canvas, c, s);
    if (!reduceMotion) _particlesLayer(canvas, c, s, spin);
    if (state == EyeScannerState.verified) _tick(canvas, c, s);
    if (state == EyeScannerState.failed) _cross(canvas, c, s);
  }

  void _background(Canvas canvas, Offset c, double s) {
    final Paint p = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          color.withValues(alpha: 0.22),
          AlmusColors.blue.withValues(alpha: 0.06),
          Colors.transparent,
        ],
        stops: const <double>[0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: c, radius: s / 2));
    canvas.drawCircle(c, s / 2, p);
  }

  void _rings(Canvas canvas, Offset c, double s, double spin) {
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: 0.28);
    canvas.drawCircle(c, s * 0.47, base);
    canvas.drawCircle(c, s * 0.40, base);

    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.9);
    if (_scanning) {
      arc.maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    }
    final double outerSpeed = _scanning ? 1 : 0.35;
    // Three arcs of the outer ring and two of the inner ring, rotating
    // in opposite directions.
    for (int i = 0; i < 3; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: s * 0.47),
        spin * outerSpeed + i * 2 * math.pi / 3,
        0.9,
        false,
        arc,
      );
    }
    arc.strokeWidth = 2;
    arc.color = AlmusColors.blue.withValues(alpha: 0.9);
    for (int i = 0; i < 2; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: s * 0.40),
        -spin * outerSpeed * 1.4 + i * math.pi,
        1.2,
        false,
        arc,
      );
    }
    // Tick marks around the outer ring.
    final Paint tick = Paint()
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.35);
    for (int i = 0; i < 48; i++) {
      final double a = i * 2 * math.pi / 48;
      final double r1 = s * 0.485;
      final double r2 = s * (i % 4 == 0 ? 0.50 : 0.495);
      canvas.drawLine(
        c + Offset(math.cos(a) * r1, math.sin(a) * r1),
        c + Offset(math.cos(a) * r2, math.sin(a) * r2),
        tick,
      );
    }
  }

  void _hudBrackets(Canvas canvas, double s) {
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = AlmusColors.purple.withValues(alpha: 0.75);
    final double m = s * 0.04;
    final double l = s * 0.09;
    // top-left, top-right, bottom-left, bottom-right
    canvas.drawPath(
      Path()
        ..moveTo(m, m + l)
        ..lineTo(m, m)
        ..lineTo(m + l, m),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(s - m - l, m)
        ..lineTo(s - m, m)
        ..lineTo(s - m, m + l),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(m, s - m - l)
        ..lineTo(m, s - m)
        ..lineTo(m + l, s - m),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(s - m - l, s - m)
        ..lineTo(s - m, s - m)
        ..lineTo(s - m, s - m - l),
      p,
    );
  }

  Path _eyePath(Offset c, double s) {
    final double w = s * 0.34;
    final double h = s * 0.19;
    return Path()
      ..moveTo(c.dx - w, c.dy)
      ..quadraticBezierTo(c.dx, c.dy - h * 2, c.dx + w, c.dy)
      ..quadraticBezierTo(c.dx, c.dy + h * 2, c.dx - w, c.dy)
      ..close();
  }

  void _eye(Canvas canvas, Offset c, double s) {
    final Path eye = _eyePath(c, s);
    canvas.drawPath(
      eye,
      Paint()..color = const Color(0xFF050914).withValues(alpha: 0.9),
    );

    canvas.save();
    canvas.clipPath(eye);

    final double irisR = s * 0.15;
    // Iris body.
    canvas.drawCircle(
      c,
      irisR,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            AlmusColors.blue.withValues(alpha: 0.95),
            color.withValues(alpha: 0.95),
            AlmusColors.purple.withValues(alpha: 0.85),
          ],
          stops: const <double>[0.2, 0.7, 1],
        ).createShader(Rect.fromCircle(center: c, radius: irisR)),
    );
    // Iris fibres.
    final Paint fibre = Paint()
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.22);
    for (int i = 0; i < _fibers; i++) {
      final double a = i * 2 * math.pi / _fibers;
      canvas.drawLine(
        c + Offset(math.cos(a) * irisR * 0.38, math.sin(a) * irisR * 0.38),
        c + Offset(math.cos(a) * irisR * 0.97, math.sin(a) * irisR * 0.97),
        fibre,
      );
    }
    // Pupil: widens a little while scanning.
    final double pulse = reduceMotion ? 0 : math.sin(t * 2 * math.pi) * 0.05;
    final double pupilR = irisR * ((_scanning ? 0.50 : 0.40) + pulse);
    canvas.drawCircle(c, pupilR, Paint()..color = Colors.black);
    // Specular highlight.
    canvas.drawCircle(
      c + Offset(-irisR * 0.35, -irisR * 0.35),
      irisR * 0.13,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();

    // Eye outline with glow.
    final Paint outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = color;
    if (_scanning) {
      canvas.drawPath(
        eye,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = color.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.drawPath(eye, outline);
  }

  void _beam(Canvas canvas, Offset c, double s) {
    // Ping-pong between the top and bottom of the eye.
    final double phase = reduceMotion ? 0.5 : 0.5 - 0.5 * math.cos(t * 2 * math.pi);
    final double top = c.dy - s * 0.24;
    final double bottom = c.dy + s * 0.24;
    final double y = top + (bottom - top) * phase;
    final double halfW = s * 0.40;
    final Rect glow = Rect.fromLTRB(c.dx - halfW, y - 10, c.dx + halfW, y + 10);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, s, s));
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.transparent,
            color.withValues(alpha: 0.45),
            Colors.transparent,
          ],
        ).createShader(glow),
    );
    canvas.drawLine(
      Offset(c.dx - halfW, y),
      Offset(c.dx + halfW, y),
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.restore();
  }

  void _particlesLayer(Canvas canvas, Offset c, double s, double spin) {
    final Paint p = Paint();
    for (int i = 0; i < _particles; i++) {
      // Deterministic positions (no random numbers, so painting is stable).
      final double phase = (i * 0.61803398875) % 1.0;
      final double radius = s * (0.30 + 0.17 * ((i * 7) % 5) / 4);
      final double speed = (i.isEven ? 1 : -1) * (0.4 + 0.1 * (i % 3));
      final double a = phase * 2 * math.pi + spin * speed;
      final double flicker = 0.35 + 0.35 * math.sin(spin * 2 + i);
      p.color = color.withValues(alpha: flicker.clamp(0.1, 0.7));
      canvas.drawCircle(
        c + Offset(math.cos(a) * radius, math.sin(a) * radius),
        1.2 + (i % 3) * 0.6,
        p,
      );
    }
  }

  void _tick(Canvas canvas, Offset c, double s) {
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = AlmusColors.mint;
    final Path path = Path()
      ..moveTo(c.dx - s * 0.09, c.dy + s * 0.01)
      ..lineTo(c.dx - s * 0.02, c.dy + s * 0.08)
      ..lineTo(c.dx + s * 0.11, c.dy - s * 0.07);
    canvas.drawPath(path, p);
  }

  void _cross(Canvas canvas, Offset c, double s) {
    final Paint p = Paint()
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = AlmusColors.error;
    final double d = s * 0.07;
    canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), p);
    canvas.drawLine(c + Offset(-d, d), c + Offset(d, -d), p);
  }

  @override
  bool shouldRepaint(_EyePainter old) =>
      old.t != t ||
      old.state != state ||
      old.color != color ||
      old.reduceMotion != reduceMotion;
}
