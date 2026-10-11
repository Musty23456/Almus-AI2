/// Who wrote a chat message.
enum MessageSender { user, assistant }

/// A single chat message (kept in memory only in Phase 1).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.sender,
    required this.timestamp,
    this.isError = false,
    this.engineLabel = 'DEMO',
  });

  final String id;
  final String text;
  final MessageSender sender;
  final DateTime timestamp;
  final bool isError;

  /// Which engine produced an assistant message, e.g. DEMO or GEMINI.
  final String engineLabel;
}
