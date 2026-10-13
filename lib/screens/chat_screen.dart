import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/chat_controller.dart';
import '../controllers/memory_controller.dart';
import '../models/chat_message.dart';
import '../models/memory_item.dart';
import '../models/robot_state.dart';
import '../theme/app_theme.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings.dart';
import '../voice/voice_settings_store.dart';
import '../widgets/empty_state.dart';
import '../widgets/memory_dialogs.dart';
import '../widgets/message_bubble.dart';
import '../widgets/robot_avatar.dart';
import '../widgets/state_pill.dart';

/// Chat UI. Replies come from the DEMO engine, not a real AI.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chat,
    this.memory,
    this.voice,
    this.voiceSettings,
  });

  final ChatController chat;

  /// Phase 6 voice features (microphone, read aloud). Null hides them all.
  final VoiceController? voice;
  final VoiceSettingsController? voiceSettings;

  /// Personal memory (Phase 4). Null hides the memory bar.
  final MemoryController? memory;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  String _inputBeforeVoice = '';
  bool _suppressTyping = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onTextChanged);
    widget.voice?.onTranscript = _onVoiceText;
    widget.voice?.onCancelled = _onVoiceCancelled;
  }

  void _onTextChanged() {
    if (_suppressTyping) return;
    widget.chat.userTyping(_input.text.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _input.removeListener(_onTextChanged);
    _input.dispose();
    final ChatController chat = widget.chat;
    final VoiceController? voice = widget.voice;
    if (voice != null) {
      voice.onTranscript = null;
      voice.onCancelled = null;
      // Leaving the chat closes the microphone and stops speech.
      Future<void>.microtask(() {
        voice.cancelListening(quiet: true);
        unawaited(voice.stopSpeaking());
      });
    }
    Future<void>.microtask(() => chat.userTyping(false));
    super.dispose();
  }

  void _send() {
    final String text = _input.text;
    if (text.trim().isEmpty || widget.chat.isBusy) return;
    _input.clear();
    _interruptVoice();
    unawaited(widget.chat.send(text));
  }

  /// A new message ends listening and any reply that is being read aloud.
  void _interruptVoice() {
    final VoiceController? voice = widget.voice;
    if (voice == null) return;
    voice.cancelListening(quiet: true);
    unawaited(voice.stopSpeaking());
  }

  /// Puts text in the message box without making the avatar think the user
  /// is typing.
  void _setInput(String text) {
    _suppressTyping = true;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _suppressTyping = false;
  }

  void _onVoiceText(String text, bool isFinal) {
    if (!mounted) return;
    final String before = _inputBeforeVoice.trimRight();
    final String joined = before.isEmpty ? text : '$before $text';
    if (!isFinal) {
      _setInput(joined);
      return;
    }
    final bool autoSend = widget.voiceSettings?.value.autoSendVoice ?? false;
    if (autoSend && !widget.chat.isBusy && joined.trim().isNotEmpty) {
      _setInput('');
      unawaited(widget.chat.send(joined));
    } else {
      // Let the user check the words (recognition can make mistakes).
      _setInput(joined);
    }
  }

  void _onVoiceCancelled() {
    if (!mounted) return;
    _setInput(_inputBeforeVoice);
  }

  void _onMicPressed() {
    final VoiceController? voice = widget.voice;
    if (voice == null) return;
    if (voice.isListening) {
      unawaited(voice.stopListening());
    } else if (voice.isPreparing) {
      voice.cancelListening();
    } else {
      _inputBeforeVoice = _input.text;
      unawaited(voice.startListening());
    }
  }

  Future<void> _toggleAutoSpeak() async {
    final VoiceSettingsController? settings = widget.voiceSettings;
    if (settings == null) return;
    final bool next = !settings.value.autoSpeak;
    await settings.save(settings.value.copyWith(autoSpeak: next));
    if (!next) await widget.voice?.stopSpeaking();
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
        if (widget.voice != null) widget.voice!,
        if (widget.voiceSettings != null) widget.voiceSettings!,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<ChatMessage> messages = widget.chat.messages;
        final bool busy = widget.chat.isBusy;
        final VoiceController? voice = widget.voice;

        return Column(
          children: <Widget>[
            _ChatHeader(
              chat: widget.chat,
              canClear: messages.isNotEmpty,
              onClear: _confirmClear,
              onNewChat: widget.chat.newConversation,
              autoSpeak: voice == null || widget.voiceSettings == null
                  ? null
                  : widget.voiceSettings!.value.autoSpeak,
              onToggleAutoSpeak: _toggleAutoSpeak,
            ),
            _EngineBanner(isDemo: widget.chat.isDemo),
            if (widget.memory != null)
              _MemoryBar(chat: widget.chat, memory: widget.memory!),
            if (widget.chat.storageNotice != null)
              _StorageNotice(text: widget.chat.storageNotice!),
            if (voice?.notice != null)
              _VoiceNotice(
                text: voice!.notice!,
                isError: voice.noticeIsError,
                onDismiss: voice.dismissNotice,
              ),
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
                        final ChatMessage m = messages[i];
                        VoidCallback? onSpeak;
                        bool speakingThis = false;
                        if (voice != null &&
                            m.sender == MessageSender.assistant &&
                            !m.isError) {
                          final VoiceController v = voice;
                          final bool stopIt = v.speakingMessageId == m.id;
                          speakingThis = stopIt;
                          onSpeak = () => unawaited(
                                stopIt ? v.stopSpeaking() : v.speakMessage(m),
                              );
                        }
                        return MessageBubble(
                          key: ValueKey<String>(m.id),
                          message: m,
                          speaking: speakingThis,
                          onSpeak: onSpeak,
                        );
                      },
                    ),
            ),
            if (voice != null && voice.micActive)
              _ListeningBar(
                voice: voice,
                language: widget.voiceSettings?.value.language ??
                    VoiceLanguage.english,
                onCancel: () => voice.cancelListening(),
                onDone: () => unawaited(voice.stopListening()),
              ),
            if (voice != null && (voice.isSpeaking || voice.isPaused))
              _SpeakingBar(voice: voice),
            _InputBar(
              controller: _input,
              onSend: busy ? null : _send,
              isDemo: widget.chat.isDemo,
              voiceEnabled: voice != null,
              micListening: voice?.micActive ?? false,
              onMic: busy ? null : _onMicPressed,
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
    this.autoSpeak,
    this.onToggleAutoSpeak,
  });

  final ChatController chat;
  final bool canClear;
  final VoidCallback onClear;
  final VoidCallback onNewChat;

  /// Null hides the speaker toggle (no voice features).
  final bool? autoSpeak;
  final VoidCallback? onToggleAutoSpeak;

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
              if (autoSpeak != null)
                IconButton(
                  key: const Key('auto_speak_toggle'),
                  tooltip: autoSpeak!
                      ? 'Automatic speech is on. Tap to turn off'
                      : 'Automatic speech is off. Tap to turn on',
                  onPressed: onToggleAutoSpeak,
                  icon: Icon(
                    autoSpeak!
                        ? Icons.volume_up_outlined
                        : Icons.volume_off_outlined,
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
    this.voiceEnabled = false,
    this.micListening = false,
    this.onMic,
  });

  final TextEditingController controller;
  final VoidCallback? onSend;
  final bool isDemo;

  /// Phase 6: show the microphone button.
  final bool voiceEnabled;
  final bool micListening;
  final VoidCallback? onMic;

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
          if (voiceEnabled) ...<Widget>[
            const SizedBox(width: 4),
            IconButton(
              key: const Key('mic_button'),
              tooltip: micListening ? 'Stop listening' : 'Voice input',
              onPressed: onMic,
              style: micListening
                  ? IconButton.styleFrom(
                      backgroundColor: cs.error.withValues(alpha: 0.15),
                      foregroundColor: cs.error,
                    )
                  : null,
              icon: Icon(micListening ? Icons.stop_rounded : Icons.mic_none),
            ),
          ],
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

/// Visible whenever the microphone is requested or open, so listening is
/// never hidden from the user. Cancel discards; Done keeps the text.
class _ListeningBar extends StatelessWidget {
  const _ListeningBar({
    required this.voice,
    required this.language,
    required this.onCancel,
    required this.onDone,
  });

  final VoiceController voice;
  final VoiceLanguage language;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool preparing = voice.isPreparing;
    final String heard = voice.transcript.trim();
    return Container(
      key: const Key('listening_bar'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: <Widget>[
          _PulsingMic(active: !preparing, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  preparing
                      ? 'Getting the microphone ready…'
                      : 'Listening (${language.label})…',
                  key: const Key('listening_label'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  heard.isNotEmpty
                      ? heard
                      : (preparing
                          ? 'Allow the microphone if Android asks.'
                          : 'Speak now. The microphone is on only while this bar is shown. Audio is not saved.'),
                  key: const Key('listening_transcript'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('cancel_listening_button'),
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
          if (!preparing)
            FilledButton(
              key: const Key('finish_listening_button'),
              onPressed: onDone,
              child: const Text('Done'),
            ),
        ],
      ),
    );
  }
}

/// A microphone icon with a soft pulse. Stays still when the system asks to
/// reduce motion.
class _PulsingMic extends StatefulWidget {
  const _PulsingMic({required this.active, required this.color});

  final bool active;
  final Color color;

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.active && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _PulsingMic oldWidget) {
    super.didUpdateWidget(oldWidget);
    didChangeDependencies();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext context, Widget? _) {
        final double t = _pulse.value;
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.12 + 0.18 * t),
          ),
          child: Icon(Icons.mic, color: widget.color),
        );
      },
    );
  }
}

/// Controls for spoken replies: pause/resume (when supported) and stop.
class _SpeakingBar extends StatelessWidget {
  const _SpeakingBar({required this.voice});

  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool paused = voice.isPaused;
    return Container(
      key: const Key('speaking_bar'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.graphic_eq, color: cs.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              paused ? 'Paused' : 'Reading the reply aloud…',
              key: const Key('speaking_label'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (voice.canPause)
            IconButton(
              key: Key(paused ? 'speech_resume_button' : 'speech_pause_button'),
              tooltip: paused ? 'Resume' : 'Pause',
              onPressed: () => unawaited(
                paused ? voice.resumeSpeaking() : voice.pauseSpeaking(),
              ),
              icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause),
            ),
          IconButton(
            key: const Key('speech_stop_button'),
            tooltip: 'Stop',
            onPressed: () => unawaited(voice.stopSpeaking()),
            icon: const Icon(Icons.stop_rounded),
          ),
        ],
      ),
    );
  }
}

/// Explains a voice problem in plain words. Not spoken aloud.
class _VoiceNotice extends StatelessWidget {
  const _VoiceNotice({
    required this.text,
    required this.isError,
    required this.onDismiss,
  });

  final String text;
  final bool isError;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color color = isError ? cs.error : cs.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Icon(
              isError ? Icons.mic_off_outlined : Icons.info_outline,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                text,
                key: const Key('voice_notice'),
                style: const TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
          ),
          IconButton(
            key: const Key('voice_notice_dismiss'),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}
