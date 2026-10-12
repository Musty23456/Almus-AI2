import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/memory_controller.dart';
import '../models/memory_item.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/empty_state.dart';
import '../widgets/glow_card.dart';
import '../widgets/memory_dialogs.dart';
import '../widgets/screen_header.dart';

enum _MemoryAction { edit, delete }

/// Personal memory: facts the user approved, suggestions waiting for a
/// decision, and the switches that control whether memory is used.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.memory});

  final MemoryController memory;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  @override
  void initState() {
    super.initState();
    if (!widget.memory.isLoaded) unawaited(widget.memory.load());
  }

  Future<void> _delete(MemoryItem item) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete memory?'),
        content: Text('"${item.text}" will be removed from this phone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_delete_memory'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final bool ok = await widget.memory.delete(item.id);
    if (!ok && mounted) {
      showMemoryToast(context, widget.memory.error ?? 'Could not delete that memory.');
    }
  }

  Future<void> _clearAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Clear all memories?'),
        content: const Text(
          'Every saved memory and pending suggestion will be permanently deleted from this phone. Your chat history is not affected. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_clear_memories'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final bool ok = await widget.memory.clearAll();
    if (!mounted) return;
    showMemoryToast(
      context,
      ok ? 'All memories deleted.' : widget.memory.error ?? 'Could not clear memories.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return ListenableBuilder(
      listenable: widget.memory,
      builder: (BuildContext context, Widget? _) {
        final MemoryController m = widget.memory;
        final List<MemoryItem> suggestions = m.suggestions;
        final List<MemoryItem> confirmed = m.confirmed;

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: <Widget>[
            const ScreenHeader(
              title: 'Memory',
              subtitle: 'What Almus may remember about you',
            ),
            const SizedBox(height: 14),
            GlowCard(
              glowColor: AlmusColors.purple,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('memory_enabled_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Use memory',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      m.enabled
                          ? 'Relevant memories are added to live AI requests and Almus may suggest new ones.'
                          : 'Off: nothing is retrieved, sent or suggested. Your saved memories stay here.',
                    ),
                    value: m.enabled,
                    onChanged: (bool value) async {
                      final bool ok = await m.setEnabled(value);
                      if (!ok && context.mounted) {
                        showMemoryToast(
                          context,
                          m.error ?? 'Could not change this setting.',
                        );
                      }
                    },
                  ),
                  const Divider(height: 20),
                  Text(
                    'Memories are stored only on this phone. When memory is on and you chat in LIVE MODE, the few memories that match your message are sent with it to your backend and on to Google Gemini. Unapproved suggestions, other memories and other chats are never sent. Almus never stores passwords, card or ID numbers, and asks before keeping sensitive topics. You can also turn memory off for a single chat.',
                    key: const Key('memory_privacy_text'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            if (m.error != null) ...<Widget>[
              const SizedBox(height: 12),
              GlowCard(
                glowColor: cs.error,
                child: Row(
                  children: <Widget>[
                    Icon(Icons.error_outline, color: cs.error),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Memory problem: ${m.error}')),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('add_memory_button'),
              onPressed: () => unawaited(addMemoryFlow(context, m)),
              icon: const Icon(Icons.add),
              label: const Text('Add a memory'),
            ),
            if (suggestions.isNotEmpty) ...<Widget>[
              const SectionLabel('Suggested by Almus'),
              for (final MemoryItem item in suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _SuggestionCard(
                    key: Key('suggestion_${item.id}'),
                    item: item,
                    onConfirm: () =>
                        unawaited(confirmSuggestionFlow(context, m, item)),
                    onEdit: () => unawaited(editMemoryFlow(context, m, item)),
                    onReject: () => unawaited(m.reject(item.id)),
                  ),
                ),
            ],
            if (m.isLoading && m.items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (confirmed.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: GlowCard(
                  child: EmptyState(
                    icon: Icons.psychology_outlined,
                    title: 'No memories yet',
                    message:
                        'Add one yourself, or say something like "I prefer short answers" in a chat and approve the suggestion. Almus only remembers what you confirm.',
                  ),
                ),
              )
            else
              for (final MemoryCategory category in MemoryCategory.values)
                ..._section(
                  context,
                  category,
                  confirmed
                      .where((MemoryItem i) => i.category == category)
                      .toList(),
                ),
            if (m.items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('clear_memories_button'),
                onPressed: () => unawaited(_clearAll()),
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Clear all memories'),
                style: OutlinedButton.styleFrom(foregroundColor: cs.error),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _section(
    BuildContext context,
    MemoryCategory category,
    List<MemoryItem> items,
  ) {
    if (items.isEmpty) return const <Widget>[];
    return <Widget>[
      SectionLabel(category.label),
      for (final MemoryItem item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _MemoryTile(
            key: Key('memory_${item.id}'),
            item: item,
            onEdit: () => unawaited(editMemoryFlow(context, widget.memory, item)),
            onDelete: () => unawaited(_delete(item)),
          ),
        ),
    ];
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({
    super.key,
    required this.item,
    required this.onEdit,
    required this.onDelete,
  });

  final MemoryItem item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GlowCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(memoryCategoryIcon(item.category), color: cs.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.text, style: const TextStyle(height: 1.35)),
                const SizedBox(height: 6),
                Text(
                  'Saved ${formatRelativeDate(item.createdAt)}'
                  '${item.updatedAt.isAfter(item.createdAt) ? ' · edited ${formatRelativeDate(item.updatedAt)}' : ''}'
                  '${item.sourceConversationId != null ? ' · from a chat' : ''}',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PopupMenuButton<_MemoryAction>(
            key: Key('menu_${item.id}'),
            tooltip: 'Memory options',
            onSelected: (_MemoryAction action) {
              switch (action) {
                case _MemoryAction.edit:
                  onEdit();
                case _MemoryAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_MemoryAction>>[
              PopupMenuItem<_MemoryAction>(
                value: _MemoryAction.edit,
                child: Text('Edit'),
              ),
              PopupMenuItem<_MemoryAction>(
                value: _MemoryAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.item,
    required this.onConfirm,
    required this.onEdit,
    required this.onReject,
  });

  final MemoryItem item;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GlowCard(
      glowColor: AlmusColors.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(memoryCategoryIcon(item.category), size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                '${item.category.label} · not confirmed',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.text, style: const TextStyle(height: 1.35)),
          const SizedBox(height: 4),
          Text(
            'Not used by the AI until you save it.',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton(
                key: Key('confirm_suggestion_${item.id}'),
                onPressed: onConfirm,
                child: const Text('Save'),
              ),
              OutlinedButton(
                key: Key('edit_suggestion_${item.id}'),
                onPressed: onEdit,
                child: const Text('Edit'),
              ),
              TextButton(
                key: Key('reject_suggestion_${item.id}'),
                onPressed: onReject,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
