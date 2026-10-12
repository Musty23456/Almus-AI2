import 'package:almus_ai/data/conversation_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(
  String id,
  String conversationId,
  String text, {
  MessageSender sender = MessageSender.user,
  DateTime? at,
  bool isError = false,
  String engine = 'DEMO',
}) {
  return ChatMessage(
    id: id,
    conversationId: conversationId,
    text: text,
    sender: sender,
    timestamp: at ?? DateTime(2026, 1, 1, 10),
    isError: isError,
    engineLabel: engine,
  );
}

Future<void> expectStorageError(Future<Object?> future) async {
  try {
    await future;
  } on StorageException {
    return;
  }
  fail('Expected a StorageException');
}

/// Behaviour every repository implementation must share.
void runRepositoryContract(
  String name,
  Future<ConversationRepository> Function() create,
) {
  group('$name repository contract', () {
    late ConversationRepository repo;

    setUp(() async {
      repo = await create();
    });

    tearDown(() async {
      await repo.close();
    });

    test('creates and retrieves a conversation with timestamps', () async {
      final DateTime t = DateTime(2026, 3, 4, 5, 6, 7);
      final Conversation c = await repo.createConversation(
        id: 'c1',
        title: '  My   first\n chat  ',
        createdAt: t,
      );
      expect(c.title, 'My first chat');

      final Conversation? loaded = await repo.getConversation('c1');
      expect(loaded, isNotNull);
      expect(loaded!.title, 'My first chat');
      expect(loaded.createdAt, t);
      expect(loaded.updatedAt, t);
      expect(loaded.messageCount, 0);
      expect(await repo.getConversation('missing'), isNull);
    });

    test('blank titles fall back to the default title', () async {
      final Conversation c = await repo.createConversation(title: '   ');
      expect(c.title, kDefaultTitle);
      expect(c.id, isNotEmpty);
    });

    test('rejects duplicate conversation ids', () async {
      await repo.createConversation(id: 'c1');
      await expectStorageError(repo.createConversation(id: 'c1'));
    });

    test('stores messages in order and keeps role, status and engine', () async {
      await repo.createConversation(id: 'c1', createdAt: DateTime(2026, 1, 1, 9));
      await repo.addMessage(msg('m1', 'c1', 'Hello', at: DateTime(2026, 1, 1, 10)));
      await repo.addMessage(msg('m2', 'c1', 'Hi there', sender: MessageSender.assistant, engine: 'GEMINI', at: DateTime(2026, 1, 1, 10, 1)));
      await repo.addMessage(msg('m3', 'c1', 'Oops', sender: MessageSender.assistant, isError: true, at: DateTime(2026, 1, 1, 10, 2)));
      await repo.addMessage(msg('m4', 'c1', 'Same time A', at: DateTime(2026, 1, 1, 10, 3)));
      await repo.addMessage(msg('m5', 'c1', 'Same time B', at: DateTime(2026, 1, 1, 10, 3)));

      final List<ChatMessage> list = await repo.loadMessages('c1');
      expect(list.map((ChatMessage m) => m.id), <String>['m1', 'm2', 'm3', 'm4', 'm5']);
      expect(list[0].sender, MessageSender.user);
      expect(list[0].role, 'user');
      expect(list[1].sender, MessageSender.assistant);
      expect(list[1].role, 'assistant');
      expect(list[1].engineLabel, 'GEMINI');
      expect(list[2].isError, isTrue);
      expect(list[2].status, MessageStatus.error);
      expect(list[0].status, MessageStatus.sent);
      expect(list[0].conversationId, 'c1');
      expect(list[0].timestamp, DateTime(2026, 1, 1, 10));
    });

    test('adding a message updates the conversation time, count and preview', () async {
      await repo.createConversation(id: 'c1', createdAt: DateTime(2026, 1, 1, 9));
      await repo.addMessage(msg('m1', 'c1', 'first', at: DateTime(2026, 1, 1, 10)));
      await repo.addMessage(msg('m2', 'c1', 'latest words', sender: MessageSender.assistant, at: DateTime(2026, 1, 1, 11)));

      final Conversation c = (await repo.getConversation('c1'))!;
      expect(c.updatedAt, DateTime(2026, 1, 1, 11));
      expect(c.messageCount, 2);
      expect(c.preview, 'latest words');
    });

    test('lists conversations with the newest activity first', () async {
      await repo.createConversation(id: 'a', title: 'A', createdAt: DateTime(2026, 1, 1, 8));
      await repo.createConversation(id: 'b', title: 'B', createdAt: DateTime(2026, 1, 1, 9));
      expect((await repo.listConversations()).map((Conversation c) => c.id), <String>['b', 'a']);

      await repo.addMessage(msg('m1', 'a', 'bump', at: DateTime(2026, 1, 2)));
      expect((await repo.listConversations()).map((Conversation c) => c.id), <String>['a', 'b']);
      expect((await repo.listConversations(limit: 1)).length, 1);
    });

    test('searches titles and message text, ignoring case', () async {
      await repo.createConversation(id: 'a', title: 'Hausa lesson');
      await repo.createConversation(id: 'b', title: 'Cooking');
      await repo.addMessage(msg('m1', 'b', 'How do I make Jollof rice?'));

      List<String> ids(List<Conversation> l) => l.map((Conversation c) => c.id).toList();
      expect(ids(await repo.listConversations(query: 'hausa')), <String>['a']);
      expect(ids(await repo.listConversations(query: 'JOLLOF')), <String>['b']);
      expect(await repo.listConversations(query: 'nothing here'), isEmpty);
      expect((await repo.listConversations(query: '  ')).length, 2);
    });

    test('search treats % and _ literally', () async {
      await repo.createConversation(id: 'a', title: 'Saved 100% done');
      await repo.createConversation(id: 'b', title: 'Plain chat');
      await repo.createConversation(id: 'c', title: 'snake_case tips');

      expect((await repo.listConversations(query: '100%')).map((Conversation c) => c.id), <String>['a']);
      expect((await repo.listConversations(query: '%')).map((Conversation c) => c.id), <String>['a']);
      expect((await repo.listConversations(query: 'e_c')).map((Conversation c) => c.id), <String>['c']);
    });

    test('renames conversations and validates the title', () async {
      await repo.createConversation(id: 'c1', title: 'Old');
      await repo.renameConversation('c1', '  New   name ');
      expect((await repo.getConversation('c1'))!.title, 'New name');

      await expectStorageError(repo.renameConversation('c1', '   '));
      await expectStorageError(repo.renameConversation('missing', 'Title'));
      expect((await repo.getConversation('c1'))!.title, 'New name');
    });

    test('deleting a conversation removes its messages only', () async {
      await repo.createConversation(id: 'a');
      await repo.createConversation(id: 'b');
      await repo.addMessage(msg('m1', 'a', 'in a'));
      await repo.addMessage(msg('m2', 'b', 'in b'));

      await repo.deleteConversation('a');

      expect(await repo.getConversation('a'), isNull);
      expect(await repo.loadMessages('a'), isEmpty);
      expect((await repo.loadMessages('b')).length, 1);
      await repo.deleteConversation('a'); // deleting twice is harmless
    });

    test('clearAll removes everything', () async {
      await repo.createConversation(id: 'a');
      await repo.addMessage(msg('m1', 'a', 'text'));
      await repo.clearAll();
      expect(await repo.listConversations(), isEmpty);
      expect(await repo.loadMessages('a'), isEmpty);
    });

    test('refuses messages for a conversation that does not exist', () async {
      await expectStorageError(repo.addMessage(msg('m1', 'ghost', 'hi')));
    });
  });
}
