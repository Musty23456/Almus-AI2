import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/chat_controller.dart';
import '../controllers/memory_controller.dart';
import '../models/chat_message.dart';
import '../models/memory_item.dart';
import '../models/robot_state.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/memory_dialogs.dart';
import '../widgets/message_bubble.dart';
import '../widgets/robot_avatar.dart';
import '../widgets/state_pill.dart';

/// Chat UI. Replies come from the DEMO engine, not a real AI.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat, this.memory});

  final ChatController chat;

  /// Personal memory (Phase 4). Null hides the memory bar.
  final MemoryController? memory;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _input.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    widget.chat.userTyping(_input.text.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _input.removeListener(_onTextChanged);
    _input.dispose();
    final ChatController chat = widget.chat;
    Future<void>.microtask(() => chat.userTyping(false));
    super.dispose();
  }

  void _send() {
    final String text = _input.text;
    if (text.trim().isEmpty || widget.chat.isBusy) return;
    _input.clear();
    unawaited(widget.chat.send(text));
  }

  Future<void> _confirmClear() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'This permanently deletes this conversation from your phone. Use New chat if you only want a fresh start.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_clear'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      widget.chat.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.chat,
        if (widget.memory != null) widget.memory!,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<ChatMessage> messages = widget.chat.messages;
        final bool busy = widget.chat.isBusy;

        return Column(
          children: <Widget>[
            _ChatHeader(
              chat: widget.chat,
              canClear: messages.isNotEmpty,
              onClear: _confirmClear,
              onNewChat: widget.chat.newConversation,
            ),
            _EngineBanner(isDemo: widget.chat.isDemo),
            if (widget.memory != null)
              _MemoryBar(chat: widget.chat, memory: widget.memory!),
            if (widget.chat.storageNotice != null)
              _StorageNotice(text: widget.chat.storageNotice!),
            Expanded(
              child: messages.isEmpty && !busy
                  ? Center(
                      child: SingleChildScrollView(
                        child: EmptyState(
                          icon: Icons.forum_outlined,
                          title: 'Start a conversation',
                          message: widget.chat.isDemo
                              ? 'Say hello or ask anything. Replies are simulated in DEMO MODE so you can test the interface. Tap a suggestion to try it.'
                              : 'Ask me anything. Replies come from Gemini through your backend. Tap a suggestion to start.',
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _suggestion('Say hello', 'Hello Almus!'),
                              _suggestion('What can you do?', 'What can you do?'),
                              if (widget.chat.isDemo)
                                _suggestion('Test error state', '/error'),
                            ],
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: messages.length + (busy ? 1 : 0),
                      itemBuilder: (BuildContext context, int index) {
                        if (busy && index == 0) {
                          return _TypingBubble(isDemo: widget.chat.isDemo);
                        }
                        final int i =
                            messages.length - 1 - (busy ? index - 1 : index);
                        return MessageBubble(
                          key: ValueKey<String>(messages[i].id),
                          message: messages[i],
                        );
                      },
                    ),
            ),
            _InputBar(
              controller: _input,
              onSend: busy ? null : _send,
              isDemo: widget.chat.isDemo,
            ),
          ],
        );
      },
    );
  }

  Widget _suggestion(String label, String prompt) {
    return ActionChip(
      label: Text(label),
      onPressed: () => unawaited(widget.chat.send(prompt)),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.chat,
    required this.canClear,
    required this.onClear,
    required this.onNewChat,
  });

  final ChatController chat;
  final bool canClear;
  final VoidCallback onClear;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: ValueListenableBuilder<RobotState>(
        valueListenable: chat.robotState,
        builder: (BuildContext context, RobotState state, Widget? _) {
          return Row(
            children: <Widget>[
              SizedBox(width: 52, child: RobotAvatar(state: state, size: 52)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      chat.conversationTitle ?? 'Almus Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    StatePill(state: state, compact: true),
                  ],
                ),
              ),
              IconButton(
                key: const Key('new_chat_button'),
                tooltip: 'New chat',
                onPressed: canClear ? onNewChat : null,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                key: const Key('clear_chat_button'),
                tooltip: 'Clear chat',
                onPressed: canClear ? onClear : null,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Shows whether memory is active for this chat, lets the user switch it off
/// for this chat, lists the memories used, and offers pending suggestions.
class _MemoryBar extends StatelessWidget {
  const _MemoryBar({required this.chat, required this.memory});

  final ChatController chat;
  final MemoryController memory;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool globallyOn = memory.enabled;
    final bool chatOff = chat.chatMemoryOff;
    final List<MemoryItem> used = chat.lastMemoryUsed;
    final List<MemoryItem> suggestions =
        globallyOn && !chatOff ? memory.suggestions : const <MemoryItem>[];

    String status;
    if (!globallyOn) {
      status = 'Memory is off (change it in the Memory tab)';
    } else if (chatOff) {
      status = 'Memory is off for this chat';
    } else if (chat.isDemo) {
      status = 'Memory is on, but unused in DEMO MODE';
    } else {
      status = 'Memory is on';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.psychology_outlined,
                size: 18,
                color: globallyOn && !chatOff ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  key: const Key('memory_bar_status'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (globallyOn)
                TextButton(
                  key: const Key('chat_memory_toggle'),
                  onPressed: () => unawaited(chat.setChatMemoryOff(!chatOff)),
                  child: Text(
                    chatOff ? 'Turn on' : 'Turn off for this chat',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
          if (used.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                key: const Key('memory_used_button'),
                onTap: () => unawaited(showUsedMemoriesSheet(context, used)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Used ${used.length} ${used.length == 1 ? 'memory' : 'memories'} in the last reply · tap to see',
                    style: TextStyle(fontSize: 12, color: cs.primary),
                  ),
                ),
              ),
            ),
          if (suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Remember this?',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    suggestions.first.text,
                    key: const Key('chat_suggestion_text'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.3),
                  ),
                  Row(
                    children: <Widget>[
                      TextButton(
                        key: const Key('chat_suggestion_confirm'),
                        onPressed: () => unawaited(
                          confirmSuggestionFlow(context, memory, suggestions.first),
                        ),
                        child: const Text('Save'),
                      ),
                      TextButton(
                        key: const Key('chat_suggestion_dismiss'),
                        onPressed: () =>
                            unawaited(memory.reject(suggestions.first.id)),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StorageNotice extends StatelessWidget {
  const _StorageNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.sd_storage_outlined, size: 18, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              key: const Key('storage_notice'),
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineBanner extends StatelessWidget {
  const _EngineBanner({required this.isDemo});

  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final Color color = isDemo ? AlmusColors.purple : AlmusColors.mint;
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final Color labelColor =
        isLight ? Color.lerp(color, Colors.black, 0.4)! : color;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            isDemo ? Icons.science_outlined : Icons.bolt_rounded,
            size: 18,
            color: labelColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: isDemo ? 'DEMO MODE' : 'LIVE MODE',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: labelColor,
                    ),
                  ),
                  TextSpan(
                    text: isDemo
                        ? ' — replies are simulated on this device. Add your backend address in Settings to use Gemini.'
                        : ' — replies come from Gemini through your backend. Free-tier limits may apply.',
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.isDemo});

  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              isDemo ? 'Almus is thinking… (demo)' : 'Almus is thinking…',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.isDemo,
  });

  final TextEditingController controller;
  final VoidCallback? onSend;
  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool enabled = onSend != null;

    OutlineInputBorder border(Color color, [double width = 1]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(26),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const Key('chat_input'),
              controller: controller,
              minLines: 1,
              maxLines: 4,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(4000),
              ],
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (String _) => onSend?.call(),
              decoration: InputDecoration(
                hintText: isDemo ? 'Message Almus (demo)…' : 'Message Almus…',
                filled: true,
                fillColor: cs.surface.withValues(alpha: 0.92),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                border: border(cs.outlineVariant),
                enabledBorder: border(cs.outlineVariant),
                focusedBorder: border(cs.primary, 1.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled ? AlmusColors.accentGradient : null,
              color: enabled ? null : cs.outlineVariant,
              boxShadow: enabled
                  ? <BoxShadow>[
                      BoxShadow(
                        color: AlmusColors.blue.withValues(alpha: 0.45),
                        blurRadius: 14,
                      ),
                    ]
                  : null,
            ),
            child: IconButton(
              key: const Key('send_button'),
              tooltip: 'Send',
              onPressed: onSend,
              icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
