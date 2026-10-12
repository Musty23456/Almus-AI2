import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import '../controllers/history_controller.dart';
import '../controllers/memory_controller.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/memory_item.dart';
import '../services/memory_extractor.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/empty_state.dart';
import '../widgets/glow_card.dart';
import '../widgets/memory_dialogs.dart';
import '../widgets/screen_header.dart';

enum _ConversationAction { open, rename, summarize, delete }

/// Saved conversations. This is a list of stored chats, not AI memory.
/// The Memory tab holds the personal memories.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.chat,
    required this.history,
    required this.onOpenChat,
    this.memory,
  });

  final ChatController chat;
  final HistoryController history;

  /// Personal memory, used for "Save summary to memory". Optional.
  final MemoryController? memory;

  /// Called after a conversation was opened, to switch to the Chat tab.
  final VoidCallback onOpenChat;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.history.refresh());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(Conversation c) async {
    final bool ok = await widget.chat.openConversation(c.id);
    if (!mounted) return;
    if (ok) {
      widget.onOpenChat();
    } else {
      _toast(widget.chat.storageNotice ?? 'Could not open that chat.');
      unawaited(widget.history.refresh());
    }
  }

  Future<void> _rename(Conversation c) async {
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _RenameDialog(initial: c.title),
    );
    if (title == null) return;
    if (cleanTitle(title) == null) {
      _toast('A title cannot be empty.');
      return;
    }
    final bool ok = await widget.chat.renameConversation(c.id, title);
    if (!ok) _toast(widget.chat.storageNotice ?? 'Could not rename that chat.');
    await widget.history.refresh();
  }

  Future<void> _saveSummary(Conversation c) async {
    final MemoryController? memory = widget.memory;
    if (memory == null) return;
    List<ChatMessage> messages;
    try {
      messages = await widget.chat.repository.loadMessages(c.id);
    } on Exception {
      _toast('Could not read that chat.');
      return;
    }
    if (!mounted) return;
    final String draft = draftConversationSummary(
      title: c.title,
      userMessages: messages
          .where((ChatMessage m) => m.sender == MessageSender.user && !m.isError)
          .map((ChatMessage m) => m.text)
          .toList(),
      messageCount: messages.length,
      date: c.updatedAt,
    );
    await addMemoryFlow(
      context,
      memory,
      title: 'Save chat summary',
      category: MemoryCategory.summary,
      text: draft,
      sourceConversationId: c.id,
      helper:
          'This summary is built from your own messages without AI. Edit it, then save. Nothing is saved until you tap Save.',
    );
  }

  Future<void> _delete(Conversation c) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          '"${c.title}" and its ${c.messageCount} messages will be permanently removed from this phone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_delete'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final bool ok = await widget.chat.deleteConversation(c.id);
    if (!ok) _toast(widget.chat.storageNotice ?? 'Could not delete that chat.');
    await widget.history.refresh();
  }

  Future<void> _clearAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'Every saved conversation and message will be permanently deleted from this phone. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_clear_history'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final bool ok = await widget.chat.clearAllHistory();
    if (!ok) _toast(widget.chat.storageNotice ?? 'Could not clear history.');
    _search.clear();
    await widget.history.setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return ListenableBuilder(
      listenable: widget.history,
      builder: (BuildContext context, Widget? _) {
        final HistoryController h = widget.history;
        final bool searching = h.query.isNotEmpty;

        Widget content;
        if (h.isLoading && h.items.isEmpty) {
          content = const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (h.error != null) {
          content = GlowCard(
            glowColor: cs.error,
            child: Column(
              children: <Widget>[
                Icon(Icons.error_outline, color: cs.error, size: 32),
                const SizedBox(height: 8),
                Text(
                  'Could not load your saved chats. ${h.error}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('retry_history'),
                  onPressed: () => unawaited(h.refresh()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          );
        } else if (h.items.isEmpty) {
          content = GlowCard(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: EmptyState(
              icon: searching ? Icons.search_off_rounded : Icons.history_rounded,
              title: searching ? 'No matches' : 'No saved conversations yet',
              message: searching
                  ? 'No conversation title or message contains "${h.query}".'
                  : 'Start a chat and it will be saved here on your phone.',
            ),
          );
        } else {
          content = Column(
            children: <Widget>[
              for (final Conversation c in h.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ConversationTile(
                    key: Key('conversation_${c.id}'),
                    conversation: c,
                    isOpen: c.id == widget.chat.conversationId,
                    onOpen: () => unawaited(_open(c)),
                    onRename: () => unawaited(_rename(c)),
                    onSummarize: widget.memory == null
                        ? null
                        : () => unawaited(_saveSummary(c)),
                    onDelete: () => unawaited(_delete(c)),
                  ),
                ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: <Widget>[
            const ScreenHeader(
              title: 'History',
              subtitle: 'Saved conversations on this phone',
            ),
            const SizedBox(height: 14),
            GlowCard(
              glowColor: AlmusColors.purple,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline, color: AlmusColors.purple),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This is a history of your chats, stored only on this phone. '
                      'Almus does not automatically remember or learn from old '
                      'conversations. When you continue a chat, only the most recent '
                      'messages of that chat are sent as context, and other chats '
                      'are never shared. Personal memories you approve live in the '
                      'Memory tab; use \u201cSave summary to memory\u201d on a chat to keep a short summary there.',
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('history_search_field'),
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (String value) => unawaited(h.setQuery(value)),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          unawaited(h.setQuery(''));
                        },
                      )
                    : null,
                filled: true,
                fillColor: cs.surface.withValues(alpha: 0.92),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
              ),
            ),
            const SizedBox(height: 14),
            content,
            if (h.items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const Key('clear_history_button'),
                onPressed: () => unawaited(_clearAll()),
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Clear all history'),
                style: OutlinedButton.styleFrom(foregroundColor: cs.error),
              ),
            ],
            const SectionLabel('Not available yet'),
            const GlowCard(
              child: Column(
                children: <Widget>[
                  _PlannedRow(
                    icon: Icons.manage_search_outlined,
                    title: 'Searching old chats by meaning',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.isOpen,
    required this.onOpen,
    required this.onRename,
    required this.onSummarize,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool isOpen;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback? onSummarize;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final int count = conversation.messageCount;

    return GlowCard(
      glowColor: isOpen ? AlmusColors.mint : null,
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: onOpen,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                if (conversation.preview.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    conversation.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.3),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '$count ${count == 1 ? 'message' : 'messages'} · ${formatRelativeDate(conversation.updatedAt)}'
                  '${isOpen ? ' · open' : ''}',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PopupMenuButton<_ConversationAction>(
            key: Key('menu_${conversation.id}'),
            tooltip: 'Conversation options',
            onSelected: (_ConversationAction action) {
              switch (action) {
                case _ConversationAction.open:
                  onOpen();
                case _ConversationAction.rename:
                  onRename();
                case _ConversationAction.summarize:
                  onSummarize?.call();
                case _ConversationAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<_ConversationAction>>[
              const PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.open,
                child: Text('Open'),
              ),
              const PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.rename,
                child: Text('Rename'),
              ),
              if (onSummarize != null)
                PopupMenuItem<_ConversationAction>(
                  key: Key('summarize_${conversation.id}'),
                  value: _ConversationAction.summarize,
                  child: const Text('Save summary to memory'),
                ),
              const PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename conversation'),
      content: TextField(
        key: const Key('rename_field'),
        controller: _controller,
        autofocus: true,
        maxLength: kMaxTitleLength,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm_rename'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
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
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
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
