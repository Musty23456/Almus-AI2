import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/glow_card.dart';
import '../widgets/screen_header.dart';

/// Placeholder for the future long-term memory feature.
/// Nothing is saved in Phase 1.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: <Widget>[
        const ScreenHeader(
          title: 'Memory',
          subtitle: 'Long-term personal memory',
        ),
        const SizedBox(height: 16),
        GlowCard(
          glowColor: AlmusColors.purple,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.info_outline, color: AlmusColors.purple),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Coming in a later phase. Persistent personal memory is not '
                  'available yet, and nothing you do in this version is saved '
                  'permanently.',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const GlowCard(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: EmptyState(
            icon: Icons.psychology_outlined,
            title: 'No memories yet',
            message:
                'When memory arrives, this is where Almus will show what it has learned about your preferences and goals. For now this page is intentionally empty.',
          ),
        ),
        const SectionLabel('Ideas for later phases'),
        GlowCard(
          child: Column(
            children: <Widget>[
              const _PlannedRow(
                icon: Icons.person_search_outlined,
                title: 'Personal facts & preferences',
              ),
              Divider(height: 24, color: cs.outlineVariant),
              const _PlannedRow(
                icon: Icons.history_rounded,
                title: 'Conversation history',
              ),
              Divider(height: 24, color: cs.outlineVariant),
              const _PlannedRow(
                icon: Icons.flag_outlined,
                title: 'Learning progress & goals',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlannedRow extends StatelessWidget {
  const _PlannedRow({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Text(
            'PLANNED',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
