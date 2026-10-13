import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// A single chat bubble with a timestamp.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onSpeak,
    this.speaking = false,
  });

  final ChatMessage message;

  /// Phase 6: when set, a small speaker button reads this reply aloud (or
  /// stops it while [speaking]). Null hides the button.
  final VoidCallback? onSpeak;

  /// True while this message is being read aloud.
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool isUser = message.sender == MessageSender.user;
    final double maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    final Color accent = message.isError ? cs.error : cs.primary;

    final BorderRadius radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isUser ? 18 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 18),
    );

    final BoxDecoration decoration = isUser
        ? BoxDecoration(
            gradient: AlmusColors.accentGradient,
            borderRadius: radius,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AlmusColors.blue.withValues(alpha: 0.25),
                blurRadius: 12,
              ),
            ],
          )
        : BoxDecoration(
            color: cs.surface.withValues(alpha: 0.92),
            borderRadius: radius,
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: decoration,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (!isUser)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              message.isError
                                  ? Icons.error_outline
                                  : Icons.auto_awesome,
                              size: 13,
                              color: accent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              message.isError
                                  ? 'ALMUS · ERROR'
                                  : 'ALMUS · ${message.engineLabel}',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Text(
                      message.text,
                      style: TextStyle(
                        color: isUser ? Colors.white : cs.onSurface,
                        height: 1.35,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  formatTime(message.timestamp),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                if (onSpeak != null)
                  IconButton(
                    key: ValueKey<String>('speak_${message.id}'),
                    tooltip: speaking ? 'Stop reading' : 'Read aloud',
                    onPressed: onSpeak,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 32),
                    padding: EdgeInsets.zero,
                    color: speaking ? cs.primary : cs.onSurfaceVariant,
                    icon: Icon(
                      speaking
                          ? Icons.stop_circle_outlined
                          : Icons.volume_up_outlined,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
