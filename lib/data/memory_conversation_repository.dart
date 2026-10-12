import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../utils/ids.dart';
import 'conversation_repository.dart';
import 'storage_exception.dart';

/// Keeps conversations in memory only. Used by tests and as a safe fallback
/// when the local database cannot be opened (nothing survives a restart).
class MemoryConversationRepository implements ConversationRepository {
  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<ChatMessage>> _messages = <String, List<ChatMessage>>{};
  final Map<String, int> _order = <String, int>{};
  int _sequence = 0;

  @override
  Future<Conversation> createConversation({
    String? id,
    String? title,
    DateTime? createdAt,
  }) async {
    final String conversationId = id ?? newId('c');
    if (_conversations.containsKey(conversationId)) {
      throw const StorageException('That conversation already exists.');
    }
    final DateTime time = createdAt ?? DateTime.now();
    final Conversation conversation = Conversation(
      id: conversationId,
      title: cleanTitle(title ?? '') ?? kDefaultTitle,
      createdAt: time,
      updatedAt: time,
    );
    _conversations[conversationId] = conversation;
    _messages[conversationId] = <ChatMessage>[];
    _order[conversationId] = _sequence++;
    return conversation;
  }

  Conversation _withStats(Conversation c) {
    final List<ChatMessage> list = _messages[c.id] ?? const <ChatMessage>[];
    return c.copyWith(
      messageCount: list.length,
      preview: list.isEmpty ? '' : list.last.text,
    );
  }

  @override
  Future<Conversation?> getConversation(String id) async {
    final Conversation? c = _conversations[id];
    return c == null ? null : _withStats(c);
  }

  @override
  Future<List<Conversation>> listConversations({
    String query = '',
    int limit = 200,
  }) async {
    final String q = query.trim().toLowerCase();
    final List<Conversation> result = _conversations.values.where((Conversation c) {
      if (q.isEmpty) return true;
      if (c.title.toLowerCase().contains(q)) return true;
      return (_messages[c.id] ?? const <ChatMessage>[])
          .any((ChatMessage m) => m.text.toLowerCase().contains(q));
    }).toList();
    result.sort((Conversation a, Conversation b) {
      final int byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : _order[b.id]!.compareTo(_order[a.id]!);
    });
    return result.take(limit).map(_withStats).toList();
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    final Conversation? c = _conversations[id];
    final String? cleaned = cleanTitle(title);
    if (cleaned == null) {
      throw const StorageException('A conversation title cannot be empty.');
    }
    if (c == null) {
      throw const StorageException('That conversation no longer exists.');
    }
    _conversations[id] = c.copyWith(title: cleaned);
  }

  @override
  Future<void> deleteConversation(String id) async {
    _conversations.remove(id);
    _messages.remove(id);
    _order.remove(id);
  }

  @override
  Future<void> clearAll() async {
    _conversations.clear();
    _messages.clear();
    _order.clear();
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    final Conversation? c = _conversations[message.conversationId];
    if (c == null) {
      throw const StorageException('That conversation no longer exists.');
    }
    _messages[c.id]!.add(message);
    if (message.timestamp.isAfter(c.updatedAt)) {
      _conversations[c.id] = c.copyWith(updatedAt: message.timestamp);
    }
    return message;
  }

  @override
  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    return List<ChatMessage>.of(_messages[conversationId] ?? const <ChatMessage>[]);
  }

  @override
  Future<void> close() async {}
}
