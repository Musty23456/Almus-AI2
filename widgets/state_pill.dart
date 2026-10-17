import 'package:flutter/material.dart';

import '../models/robot_state.dart';
import '../theme/app_theme.dart';

/// Small pill that shows the current robot state.
class StatePill extends StatelessWidget {
  const StatePill({super.key, required this.state, this.compact = false});

  final RobotState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final Color color = AlmusColors.forState(state);
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final Color textColor =
        isLight ? Color.lerp(color, Colors.black, 0.4)! : color;
    final String label = compact
        ? state.label.toUpperCase()
        : 'ROBOT STATE · ${state.label.toUpperCase()}';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 3 : 7,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 10.5 : 12,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
