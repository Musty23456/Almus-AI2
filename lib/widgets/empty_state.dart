import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Friendly empty-state block with an icon, title, message and optional extra.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.child,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  AlmusColors.cyan.withValues(alpha: 0.22),
                  AlmusColors.purple.withValues(alpha: 0.22),
                ],
              ),
              border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: cs.primary.withValues(alpha: 0.18),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Icon(icon, size: 38, color: cs.primary),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (child != null) ...<Widget>[
            const SizedBox(height: 18),
            child!,
          ],
        ],
      ),
    );
  }
}
