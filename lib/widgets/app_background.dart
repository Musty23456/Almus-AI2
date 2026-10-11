import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen gradient behind every screen.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final SystemUiOverlayStyle overlay =
        (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(statusBarColor: Colors.transparent);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const <Color>[
                    Color(0xFF0B1238),
                    Color(0xFF070B1A),
                    Color(0xFF0C0822),
                  ]
                : const <Color>[Color(0xFFF3F6FF), Color(0xFFE6ECFF)],
          ),
        ),
        child: child,
      ),
    );
  }
}
