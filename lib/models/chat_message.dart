import '../attachments/attachment_models.dart';

/// Who wrote a chat message.
enum MessageSender { user, assistant }

/// Delivery state stored with each message.
enum MessageStatus { sent, error }

/// A single chat message. This is also the stored "Message" model:
/// `sender` is saved as the role (user/assistant), `text` as the content,
/// and `timestamp` as the creation time.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.sender,
    required this.timestamp,
    this.isError = false,
    this.engineLabel = 'DEMO',
    this.conversationId = '',
    this.attachments = const <AttachmentInfo>[],
  });

  final String id;
  final String text;
  final MessageSender sender;
  final DateTime timestamp;
  final bool isError;

  /// Which engine produced an assistant message, e.g. DEMO or GEMINI.
  final String engineLabel;

  /// The conversation this message belongs to ('' until it is attached to one).
  final String conversationId;

  /// Files attached to this message (kept for display while the app is open;
  /// the stored text also lists them). File content is never kept.
  final List<AttachmentInfo> attachments;

  /// 'user' or 'assistant' as stored in the database.
  String get role => sender == MessageSender.user ? 'user' : 'assistant';

  MessageStatus get status => isError ? MessageStatus.error : MessageStatus.sent;
}
