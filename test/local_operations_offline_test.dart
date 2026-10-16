import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/controllers/history_controller.dart';
import 'package:almus_ai/controllers/memory_controller.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/data/volatile_memory_repository.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/conversation.dart';
import 'package:almus_ai/models/memory_item.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine whose every provider is down.
class _AllProvidersDown implements ChatService {
  @override
  bool get isDemo => false;

  @override
  String get engineName => 'LIVE';

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async {
    throw const ChatServiceException(
      'None of the allowed AI providers could answer.',
      code: 'all_providers_failed',
    );
  }
}

void main() {
  test('with every AI provider down, local features still work', () async {
    final MemoryConversationRepository repo = MemoryConversationRepository();
    final ChatController chat = ChatController(service: _AllProvidersDown(), repository: repo);
    addTearDown(chat.dispose);

    // The AI request fails with a clear error...
    await chat.send('hello offline world');
    expect(chat.messages.last.isError, isTrue);
    expect(chat.messages.last.text, contains('None of the allowed AI providers'));
    await chat.flushStorage();

    // ...but the conversation is saved and can be reopened and searched locally.
    final HistoryController history = HistoryController(repo);
    addTearDown(history.dispose);
    await history.refresh();
    expect(history.items, hasLength(1));
    await history.setQuery('offline');
    expect(history.items, hasLength(1));
    final Conversation saved = history.items.first;
    final List<ChatMessage> reopened = await repo.loadMessages(saved.id);
    expect(reopened.first.text, 'hello offline world');

    // Memory can be written and read without any provider.
    final MemoryController memory = MemoryController(VolatileMemoryRepository());
    addTearDown(memory.dispose);
    final MemorySaveResult result = await memory.add(category: MemoryCategory.preference, text: 'I like short answers');
    expect(result.status, MemorySaveStatus.saved);
    await memory.load();
    expect(memory.items.map((MemoryItem m) => m.text), contains('I like short answers'));

    // Starting a fresh chat is still possible.
    chat.newConversation();
    expect(chat.messages, isEmpty);
  });

  test('a failing provider does not make the chat controller unusable afterwards', () async {
    final ChatController chat = ChatController(service: _AllProvidersDown(), repository: MemoryConversationRepository());
    addTearDown(chat.dispose);
    await chat.send('first');
    await chat.send('second');
    await chat.flushStorage();
    expect(chat.messages.where((ChatMessage m) => m.isError), hasLength(2));
  });
}
