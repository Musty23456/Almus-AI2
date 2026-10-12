import 'package:almus_ai/app.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/conversation.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:almus_ai/utils/formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<MemoryConversationRepository> _seed(WidgetTester tester) async {
  final MemoryConversationRepository repo = MemoryConversationRepository();
  await tester.runAsync(() async {
    await repo.createConversation(id: 'c1', title: 'Hausa lesson', createdAt: DateTime(2026, 1, 1, 9));
    await repo.addMessage(ChatMessage(
      id: 'm1', conversationId: 'c1', text: 'Sannu, teach me greetings',
      sender: MessageSender.user, timestamp: DateTime.utc(2026, 1, 1, 9, 1),
    ));
    await repo.addMessage(ChatMessage(
      id: 'm2', conversationId: 'c1', text: 'Barka da zuwa!',
      sender: MessageSender.assistant, timestamp: DateTime(2026, 1, 1, 9, 2),
    ));
    await repo.createConversation(id: 'c2', title: 'Flutter tips', createdAt: DateTime(2026, 1, 2, 9));
    await repo.addMessage(ChatMessage(
      id: 'm3', conversationId: 'c2', text: 'How do I use sqflite?',
      sender: MessageSender.user, timestamp: DateTime(2026, 1, 2, 9, 1),
    ));
  });
  return repo;
}

Widget _app(MemoryConversationRepository repo) => AlmusApp(
      showSplash: false,
      repository: repo,
      settingsStore: MemorySettingsStore(),
      chatService: DemoChatService(thinkingDelay: Duration.zero),
    );

Future<void> _openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  test('formatRelativeDate describes today, yesterday and older dates', () {
    final DateTime now = DateTime(2026, 10, 12, 15);
    expect(formatRelativeDate(DateTime(2026, 10, 12, 9, 5), now: now), 'Today 09:05');
    expect(formatRelativeDate(DateTime(2026, 10, 11, 23, 59), now: now), 'Yesterday 23:59');
    expect(formatRelativeDate(DateTime(2026, 3, 4, 8), now: now), '4 Mar');
    expect(formatRelativeDate(DateTime(2025, 12, 31, 8), now: now), '31 Dec 2025');
  });

  testWidgets('history lists saved conversations, newest first, with honest wording',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    expect(find.text('Flutter tips'), findsOneWidget);
    expect(find.text('Hausa lesson'), findsOneWidget);
    expect(find.textContaining('2 messages'), findsOneWidget);
    expect(find.textContaining('does not automatically remember'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Flutter tips')).dy,
      lessThan(tester.getTopLeft(find.text('Hausa lesson')).dy),
    );
  });

  testWidgets('search finds conversations by title and by message text',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    await tester.enterText(find.byKey(const Key('history_search_field')), 'sqflite');
    await _settle(tester);
    expect(find.text('Flutter tips'), findsOneWidget);
    expect(find.text('Hausa lesson'), findsNothing);

    await tester.enterText(find.byKey(const Key('history_search_field')), 'zzz');
    await _settle(tester);
    expect(find.text('No matches'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('history_search_field')), 'hausa');
    await _settle(tester);
    expect(find.text('Hausa lesson'), findsOneWidget);
  });

  testWidgets('opening a conversation shows its messages in Chat',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    await tester.tap(find.byKey(const Key('conversation_c1')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Sannu, teach me greetings'), findsOneWidget);
    expect(find.text('Barka da zuwa!'), findsOneWidget);
    expect(find.text('Hausa lesson'), findsOneWidget); // chat header title
  });

  testWidgets('the latest conversation is restored when the app starts',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.chat_bubble_outline);

    expect(find.text('How do I use sqflite?'), findsOneWidget);
    expect(find.text('Start a conversation'), findsNothing);
  });

  testWidgets('renaming a conversation updates the list', (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    await tester.tap(find.byKey(const Key('menu_c1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('rename_field')), 'Learning Hausa');
    await tester.tap(find.byKey(const Key('confirm_rename')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);

    expect(find.text('Learning Hausa'), findsOneWidget);
    expect(find.text('Hausa lesson'), findsNothing);
    final List<Conversation> stored =
        (await tester.runAsync(() => repo.listConversations()))!;
    expect(stored.any((Conversation c) => c.title == 'Learning Hausa'), isTrue);
  });

  testWidgets('deleting a conversation asks for confirmation',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    await tester.tap(find.byKey(const Key('menu_c2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Delete conversation?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Flutter tips'), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu_c2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('confirm_delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);

    expect(find.text('Flutter tips'), findsNothing);
    expect(find.text('Hausa lesson'), findsOneWidget);
  });

  testWidgets('clear all history needs confirmation and empties the list',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = await _seed(tester);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.history_outlined);
    await _settle(tester);

    await tester.tap(find.byKey(const Key('clear_history_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Clear all history?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_clear_history')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);

    expect(find.text('No saved conversations yet'), findsOneWidget);
    final List<Conversation> stored =
        (await tester.runAsync(() => repo.listConversations()))!;
    expect(stored, isEmpty);
  });

  testWidgets('chatting saves the conversation and New chat keeps the old one',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemoryConversationRepository repo = MemoryConversationRepository();
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 8));

    List<Conversation> stored = (await tester.runAsync(() => repo.listConversations()))!;
    expect(stored.length, 1);
    expect(stored.single.title, 'hello');
    expect(stored.single.messageCount, 2);

    await tester.tap(find.byKey(const Key('new_chat_button')));
    await tester.pump();
    expect(find.text('Start a conversation'), findsOneWidget);

    stored = (await tester.runAsync(() => repo.listConversations()))!;
    expect(stored.length, 1);
  });
}
