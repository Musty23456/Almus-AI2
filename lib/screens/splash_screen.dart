import 'dart:async';

import 'package:flutter/material.dart';

import '../models/robot_state.dart';
import '../widgets/gradient_text.dart';
import '../widgets/robot_avatar.dart';

/// Branded splash shown briefly on launch.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.onFinished,
    this.duration = const Duration(milliseconds: 2400),
  });

  final VoidCallback onFinished;
  final Duration duration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(widget.duration, widget.onFinished);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Animation<double> fade = _controller.drive(
      CurveTween(curve: const Interval(0, 0.4, curve: Curves.easeOut)),
    );
    final Animation<double> scale = _controller.drive(
      Tween<double>(begin: 0.9, end: 1).chain(
        CurveTween(curve: const Interval(0, 0.5, curve: Curves.easeOutBack)),
      ),
    );

    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const RobotAvatar(state: RobotState.idle, size: 170),
                const SizedBox(height: 16),
                GradientText(
                  'ALMUS AI',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'PERSONAL ASSISTANT',
                  style: theme.textTheme.labelLarge?.copyWith(
                    letterSpacing: 4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                AnimatedBuilder(
                  animation: _controller,
                  builder: (BuildContext context, Widget? child) => SizedBox(
                    width: 140,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _controller.value,
                        minHeight: 3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
