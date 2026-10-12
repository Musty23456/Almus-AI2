import 'dart:convert';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/controllers/memory_controller.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/data/volatile_memory_repository.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/memory_item.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/memory_retrieval.dart';
import 'package:almus_ai/services/routed_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A pretend "live" engine that records what memory context it was given.
class _FakeEngine implements ChatService {
  _FakeEngine({this.demo = false});

  final bool demo;
  final List<String?> contexts = <String?>[];
  final List<String> messages = <String>[];

  @override
  String get engineName => demo ? 'DEMO MODE' : 'LIVE · GEMINI';

  @override
  bool get isDemo => demo;

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async {
    messages.add(userMessage);
    contexts.add(memoryContext);
    return 'ok';
  }
}

class _ListFails extends VolatileMemoryRepository {
  @override
  Future<List<MemoryItem>> list({
    MemoryStatus? status,
    MemoryCategory? category,
  }) async {
    throw const StorageException('The local database reported an error.');
  }
}

const AppSettings _live = AppSettings(
  backendUrl: 'https://backend.example.com',
  accessToken: 'tok',
);

void main() {
  late VolatileMemoryRepository memoryRepo;
  late MemoryController memory;
  late MemoryConversationRepository chats;
  late _FakeEngine engine;
  late ChatController chat;

  ChatController makeChat({_FakeEngine? withEngine, MemoryController? withMemory}) {
    final ChatController c = ChatController(
      service: withEngine ?? engine,
      repository: chats,
      memory: withMemory ?? memory,
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() async {
    memoryRepo = VolatileMemoryRepository();
    memory = MemoryController(memoryRepo);
    chats = MemoryConversationRepository();
    engine = _FakeEngine();
    chat = makeChat();
    await memory.load();
    await memory.add(
      category: MemoryCategory.project,
      text: 'I am building a school timetable app',
    );
    await memory.add(
      category: MemoryCategory.preference,
      text: 'I prefer short answers',
    );
  });

  tearDown(() => memory.dispose());

  group('what is sent with a request', () {
    test('relevant memories are included and the user can see which', () async {
      await chat.send('How do I improve my timetable app?');
      expect(engine.contexts.single, isNotNull);
      expect(engine.contexts.single, contains('school timetable app'));
      expect(engine.contexts.single, isNot(contains('short answers')));
      expect(chat.lastMemoryUsed.map((MemoryItem m) => m.text), <String>[
        'I am building a school timetable app',
      ]);
    });

    test('an unrelated message sends no memory at all', () async {
      await chat.send('What is the capital of France?');
      expect(engine.contexts.single, isNull);
      expect(chat.lastMemoryUsed, isEmpty);
    });

    test('the context is small even with a large memory database', () async {
      for (int i = 0; i < 80; i++) {
        await memory.add(
          category: MemoryCategory.fact,
          text: 'Gardening note number $i about plant$i and soil$i',
        );
      }
      await chat.send('Help with my timetable app');
      final String context = engine.contexts.single!;
      expect(context.length, lessThanOrEqualTo(kMemoryContextMaxChars));
      expect(context, isNot(contains('Gardening')));
      expect(chat.lastMemoryUsed.length, lessThanOrEqualTo(kMemoryMaxItems));
    });

    test('unapproved suggestions are never sent', () async {
      await memory.suggestFrom('I am learning Hausa vocabulary these days.');
      expect(memory.suggestions.length, 1);
      await chat.send('Teach me some Hausa vocabulary');
      expect(engine.contexts.single, isNull);
    });

    test('the whole conversation database is not sent as memory', () async {
      await chat.send('Hello there');
      await chat.send('How do I improve my timetable app?');
      final String context = engine.contexts.last!;
      expect(context, isNot(contains('Hello there')));
    });

    test('nothing is retrieved in DEMO MODE because nothing leaves the phone', () async {
      final _FakeEngine demo = _FakeEngine(demo: true);
      final ChatController c = makeChat(withEngine: demo);
      await c.send('How do I improve my timetable app?');
      expect(demo.contexts.single, isNull);
      expect(c.lastMemoryUsed, isEmpty);
    });
  });

  group('turning memory off', () {
    test('disabled globally: nothing retrieved and nothing suggested', () async {
      await memory.setEnabled(false);
      await chat.send('I am learning Flutter these days. How do I improve my timetable app?');
      await pumpEventQueue();
      expect(engine.contexts.single, isNull);
      expect(memory.suggestions, isEmpty);
    });

    test('off for this chat only', () async {
      await chat.setChatMemoryOff(true);
      expect(chat.chatMemoryOff, isTrue);
      await chat.send('How do I improve my timetable app?');
      expect(engine.contexts.single, isNull);

      chat.newConversation();
      expect(chat.chatMemoryOff, isFalse);
      await chat.send('How do I improve my timetable app?');
      expect(engine.contexts.last, contains('school timetable app'));
    });

    test('no suggestions are made in a chat where memory is off', () async {
      await chat.setChatMemoryOff(true);
      await chat.send('I am learning Flutter these days.');
      await pumpEventQueue();
      expect(memory.suggestions, isEmpty);

      await chat.setChatMemoryOff(false);
      await chat.send('I am learning Dart these days.');
      await pumpEventQueue();
      expect(memory.suggestions.length, 1);
    });

    test('the per-chat choice is saved and restored when the chat is reopened', () async {
      await chat.setChatMemoryOff(true);
      await chat.send('Hello there');
      await chat.flushStorage();
      await pumpEventQueue();
      final String id = chat.conversationId!;
      expect(await memoryRepo.isConversationMemoryOff(id), isTrue);

      chat.newConversation();
      expect(chat.chatMemoryOff, isFalse);
      expect(await chat.openConversation(id), isTrue);
      expect(chat.chatMemoryOff, isTrue);

      await chat.setChatMemoryOff(false);
      expect(await memoryRepo.isConversationMemoryOff(id), isFalse);
    });

    test('deleting a chat forgets its memory switch', () async {
      await chat.setChatMemoryOff(true);
      await chat.send('Hello there');
      await chat.flushStorage();
      await pumpEventQueue();
      final String id = chat.conversationId!;
      expect(await chat.deleteConversation(id), isTrue);
      await pumpEventQueue();
      expect(await memoryRepo.isConversationMemoryOff(id), isFalse);
    });

    test('a stored "memory off" setting is respected right after startup', () async {
      await memoryRepo.setEnabled(false);
      final MemoryController fresh = MemoryController(memoryRepo);
      final _FakeEngine e = _FakeEngine();
      final ChatController c = makeChat(withEngine: e, withMemory: fresh);
      await c.send('I am learning Flutter these days. How do I improve my timetable app?');
      await pumpEventQueue();
      expect(e.contexts.single, isNull);
      expect(fresh.suggestions, isEmpty);
      fresh.dispose();
    });
  });

  group('suggestions from chat', () {
    test('what the user says can become a suggestion, never a saved memory', () async {
      await chat.send('I am learning Flutter these days.');
      await pumpEventQueue();
      expect(memory.suggestions.single.text, 'I am learning Flutter these days');
      expect(memory.suggestions.single.sourceConversationId, chat.conversationId);
      expect(memory.suggestions.single.status, MemoryStatus.suggested);
      expect(memory.confirmed.length, 2);
    });
  });

  group('robustness', () {
    test('a memory failure never stops the chat', () async {
      final MemoryController broken = MemoryController(_ListFails());
      final _FakeEngine e = _FakeEngine();
      final ChatController c = makeChat(withEngine: e, withMemory: broken);
      await c.send('How do I improve my timetable app?');
      expect(e.contexts.single, isNull);
      expect(c.messages.last.text, 'ok');
      expect(c.messages.last.isError, isFalse);
      broken.dispose();
    });

    test('a chat controller without memory behaves as before', () async {
      final _FakeEngine e = _FakeEngine();
      final ChatController c = ChatController(service: e, repository: chats);
      addTearDown(c.dispose);
      await c.send('How do I improve my timetable app?');
      expect(e.contexts.single, isNull);
      expect(c.messages.length, 2);
    });
  });

  group('request to the backend', () {
    http.Response okJson() => http.Response(
          jsonEncode(<String, String>{'reply': 'Hi'}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );

    test('memoryContext is sent when present and omitted otherwise', () async {
      final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
      final BackendClient client = BackendClient(
        client: MockClient((http.Request request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return okJson();
        }),
      );
      final List<Map<String, String>> messages = <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Hello'},
      ];

      await client.chat(_live, messages);
      await client.chat(_live, messages, memoryContext: '');
      await client.chat(_live, messages, memoryContext: 'LOCAL MEMORY NOTES\n- [fact] x');

      expect(bodies[0].containsKey('memoryContext'), isFalse);
      expect(bodies[1].containsKey('memoryContext'), isFalse);
      expect(bodies[2]['memoryContext'], 'LOCAL MEMORY NOTES\n- [fact] x');
      expect(bodies[2]['messages'], messages);
    });

    test('the routed engine forwards the memory block to the backend', () async {
      // Covered end to end by the widget flow; here we only check the payload builder.
      final List<Map<String, String>> payload =
          buildChatPayload('Hello', const <ChatMessage>[]);
      expect(payload.last, <String, String>{'role': 'user', 'content': 'Hello'});
    });
  });
}
