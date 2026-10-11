import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import '../models/robot_state.dart';
import '../theme/app_theme.dart';
import '../utils/app_info.dart';
import '../widgets/glow_card.dart';
import '../widgets/gradient_text.dart';
import '../widgets/robot_avatar.dart';
import '../widgets/state_pill.dart';

/// Home: branding, robot avatar, welcome text and quick actions.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.chat, required this.onNavigate});

  final ChatController chat;
  final ValueChanged<int> onNavigate;

  void _showProfile(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircleAvatar(
                radius: 32,
                child: Icon(Icons.smart_toy_outlined, size: 32),
              ),
              const SizedBox(height: 12),
              Text(
                'ALMUS AI',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              Text(
                'Personal Assistant',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Almus is designed as a personal assistant for a single user. '
                'Accounts and personalised profiles are not part of Phase 1.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Version ${AppInfo.version} · ${AppInfo.phase}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final double avatarSize =
        math.min(260.0, MediaQuery.sizeOf(context).width * 0.68);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: AlmusColors.accentGradient,
                borderRadius: BorderRadius.circular(11),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AlmusColors.blue.withValues(alpha: 0.4),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            GradientText(
              'ALMUS AI',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Profile',
              onPressed: () => _showProfile(context),
              icon: CircleAvatar(
                radius: 17,
                backgroundColor: cs.primary.withValues(alpha: 0.15),
                child: Icon(Icons.person_outline, size: 20, color: cs.primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<RobotState>(
          valueListenable: chat.robotState,
          builder: (BuildContext context, RobotState state, Widget? _) {
            return Column(
              children: <Widget>[
                Center(child: RobotAvatar(state: state, size: avatarSize)),
                const SizedBox(height: 4),
                StatePill(state: state),
                const SizedBox(height: 8),
                Text(
                  state.description,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 22),
        Text(
          'Welcome back',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'ALMUS AI is your personal assistant, built to grow into a teacher, '
          'programming partner, research aide, adviser and companion with '
          'long-term memory. Connect your Gemini backend in Settings for real '
          'answers; until then chat runs in DEMO MODE.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'PREVIEW ROBOT STATES',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        ValueListenableBuilder<RobotState>(
          valueListenable: chat.robotState,
          builder: (BuildContext context, RobotState current, Widget? _) {
            return Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final RobotState s in RobotState.values)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: current == s,
                    onSelected: (bool _) => chat.setRobotState(s),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickAction(
                key: const Key('quick_start_chat'),
                icon: Icons.chat_bubble_rounded,
                label: 'Start Chat',
                color: AlmusColors.cyan,
                onTap: () => onNavigate(1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAction(
                key: const Key('quick_memory'),
                icon: Icons.psychology_rounded,
                label: 'My Memory',
                color: AlmusColors.purple,
                onTap: () => onNavigate(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAction(
                key: const Key('quick_settings'),
                icon: Icons.settings_rounded,
                label: 'Settings',
                color: AlmusColors.blue,
                onTap: () => onNavigate(3),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlowCard(
      glowColor: color,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
