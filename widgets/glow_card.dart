import 'package:flutter/material.dart';

/// A rounded card with a subtle coloured border and glow.
class GlowCard extends StatelessWidget {
  const GlowCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.glowColor,
    this.radius = 20,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? glowColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color glow = glowColor ?? cs.primary;
    final BorderRadius borderRadius = BorderRadius.circular(radius);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: isDark ? 0.85 : 1.0),
        borderRadius: borderRadius,
        border: Border.all(color: glow.withValues(alpha: 0.28)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: glow.withValues(alpha: isDark ? 0.12 : 0.08),
            blurRadius: 18,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
