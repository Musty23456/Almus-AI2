import 'dart:io';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/data/app_database.dart';
import 'package:almus_ai/data/conversation_repository.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/data/sqlite_conversation_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/conversation.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Repository whose writes fail, to prove chatting never breaks.
class _FailingWrites extends MemoryConversationRepository {
  @override
  Future<Conversation> createConversation({String? id, String? title, DateTime? createdAt}) {
    throw const StorageException('disk is full.');
  }
}

/// Repository whose reads fail.
class _FailingReads extends MemoryConversationRepository {
  @override
  Future<List<Conversation>> listConversations({String query = '', int limit = 200}) {
    throw const StorageException('database is locked.');
  }
}

ChatController _controller(ConversationRepository repo, {bool persistent = true}) {
  return ChatController(
    service: DemoChatService(thinkingDelay: Duration.zero),
    repository: repo,
    persistent: persistent,
  );
}

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('almus_chat_');
    path = p.join(dir.path, 'chat.db');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppDatabase> open() => AppDatabase.open(factory: databaseFactoryFfi, path: path);

  test('a conversation is created lazily and titled from the first message', () async {
    final MemoryConversationRepository repo = MemoryConversationRepository();
    final ChatController chat = _controller(repo);

    expect(chat.conversationId, isNull);
    expect(await repo.listConversations(), isEmpty);

    await chat.send('How do I learn Flutter animations properly and quickly?');
    await chat.flushStorage();

    final List<Conversation> list = await repo.listConversations();
    expect(list.length, 1);
    expect(list.single.title, 'How do I learn Flutter animations proper…');
    expect(list.single.messageCount, 2);
    expect(chat.conversationTitle, list.single.title);
    chat.dispose();
  });

  test('chat is restored after the app restarts', () async {
    final AppDatabase db1 = await open();
    final ChatController first = _controller(SqliteConversationRepository(db1));
    await first.send('hello');
    await first.flushStorage();
    final String id = first.conversationId!;
    first.dispose();
    await db1.close();

    final AppDatabase db2 = await open();
    final ChatController second = _controller(SqliteConversationRepository(db2));
    expect(second.messages, isEmpty);
    await second.restoreLatest();

    expect(second.conversationId, id);
    expect(second.messages.length, 2);
    expect(second.messages.first.text, 'hello');
    expect(second.messages.first.sender, MessageSender.user);
    expect(second.messages.last.sender, MessageSender.assistant);
    expect(second.conversationTitle, 'hello');
    second.dispose();
    await db2.close();
  });

  test('new chats stay separate and old ones can be reopened and continued', () async {
    final AppDatabase db = await open();
    final SqliteConversationRepository repo = SqliteConversationRepository(db);
    final ChatController chat = _controller(repo);

    await chat.send('first topic');
    await chat.flushStorage();
    final String firstId = chat.conversationId!;

    chat.newConversation();
    expect(chat.messages, isEmpty);
    expect(chat.conversationId, isNull);

    await chat.send('second topic');
    await chat.flushStorage();
    final String secondId = chat.conversationId!;
    expect(secondId, isNot(firstId));
    expect((await repo.listConversations()).length, 2);

    expect(await chat.openConversation(firstId), isTrue);
    expect(chat.messages.first.text, 'first topic');
    await chat.send('more on the first');
    await chat.flushStorage();

    expect((await repo.loadMessages(firstId)).length, 4);
    expect((await repo.loadMessages(secondId)).length, 2);
    chat.dispose();
    await db.close();
  });

  test('renaming, deleting and clearing history work through the controller', () async {
    final AppDatabase db = await open();
    final SqliteConversationRepository repo = SqliteConversationRepository(db);
    final ChatController chat = _controller(repo);

    await chat.send('one');
    await chat.flushStorage();
    final String id = chat.conversationId!;

    expect(await chat.renameConversation(id, '  Renamed  chat '), isTrue);
    expect(chat.conversationTitle, 'Renamed chat');
    expect((await repo.getConversation(id))!.title, 'Renamed chat');

    expect(await chat.deleteConversation(id), isTrue);
    expect(chat.messages, isEmpty);
    expect(chat.conversationId, isNull);
    expect(await repo.listConversations(), isEmpty);

    await chat.send('two');
    await chat.flushStorage();
    chat.newConversation();
    await chat.send('three');
    await chat.flushStorage();
    expect((await repo.listConversations()).length, 2);

    expect(await chat.clearAllHistory(), isTrue);
    expect(await repo.listConversations(), isEmpty);
    expect(chat.messages, isEmpty);
    chat.dispose();
    await db.close();
  });

  test('clear() deletes the open conversation from storage', () async {
    final MemoryConversationRepository repo = MemoryConversationRepository();
    final ChatController chat = _controller(repo);
    await chat.send('to be removed');
    await chat.flushStorage();

    chat.clear();
    expect(chat.messages, isEmpty);
    await chat.flushStorage();
    expect(await repo.listConversations(), isEmpty);
    chat.dispose();
  });

  test('a database failure never blocks chatting and shows a safe notice', () async {
    final ChatController chat = _controller(_FailingWrites());
    await chat.send('private words');
    await chat.flushStorage();

    expect(chat.messages.length, 2);
    expect(chat.storageNotice, contains('Could not save'));
    expect(chat.storageNotice, isNot(contains('private words')));
    chat.dispose();
  });

  test('read failures are reported without crashing', () async {
    final ChatController chat = _controller(_FailingReads());
    await chat.restoreLatest();
    expect(chat.storageNotice, contains('Could not load'));
    expect(chat.messages, isEmpty);
    chat.dispose();
  });

  test('opening a missing conversation reports an error', () async {
    final ChatController chat = _controller(MemoryConversationRepository());
    expect(await chat.openConversation('nope'), isFalse);
    expect(chat.storageNotice, contains('no longer exists'));
    chat.dispose();
  });

  test('persistent false warns that history is not saved', () async {
    final ChatController chat = _controller(MemoryConversationRepository(), persistent: false);
    expect(chat.storageNotice, contains('cannot be saved'));
    chat.dispose();
  });

  test('error messages are stored with an error status', () async {
    final MemoryConversationRepository repo = MemoryConversationRepository();
    final ChatController chat = _controller(repo);
    await chat.send('/error');
    await chat.flushStorage();

    final List<ChatMessage> stored = await repo.loadMessages(chat.conversationId!);
    expect(stored.length, 2);
    expect(stored.last.status, MessageStatus.error);
    chat.dispose();
  });
}
