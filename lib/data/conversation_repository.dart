import '../models/chat_message.dart';
import '../models/conversation.dart';

/// Storage contract for conversations and messages.
/// The UI only depends on this interface, never on SQLite directly.
abstract class ConversationRepository {
  /// Creates a conversation. [id] and [createdAt] default to new values.
  Future<Conversation> createConversation({
    String? id,
    String? title,
    DateTime? createdAt,
  });

  Future<Conversation?> getConversation(String id);

  /// Newest activity first. A non-empty [query] matches titles and message text.
  Future<List<Conversation>> listConversations({String query = '', int limit = 200});

  Future<void> renameConversation(String id, String title);

  /// Deletes a conversation and all of its messages.
  Future<void> deleteConversation(String id);

  /// Deletes every conversation and message.
  Future<void> clearAll();

  /// Stores a message and bumps the conversation's update time.
  Future<ChatMessage> addMessage(ChatMessage message);

  /// Messages of a conversation, oldest first.
  Future<List<ChatMessage>> loadMessages(String conversationId);

  Future<void> close();
}
