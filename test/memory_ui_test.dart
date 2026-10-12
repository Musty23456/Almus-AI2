import 'package:almus_ai/app.dart';
import 'package:almus_ai/data/volatile_memory_repository.dart';
import 'package:almus_ai/models/memory_item.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

MemoryItem _item(
  String id,
  String text, {
  MemoryCategory category = MemoryCategory.fact,
  MemoryStatus status = MemoryStatus.confirmed,
}) {
  final DateTime t = DateTime(2026, 10, 1, 9);
  return MemoryItem(
    id: id,
    category: category,
    text: text,
    createdAt: t,
    updatedAt: t,
    status: status,
  );
}

Widget _app(VolatileMemoryRepository memory) => AlmusApp(
      showSplash: false,
      memoryRepository: memory,
      settingsStore: MemorySettingsStore(),
      chatService: DemoChatService(thinkingDelay: Duration.zero),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openMemory(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.psychology_outlined));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
}

Future<VolatileMemoryRepository> _seeded(
  WidgetTester tester,
  List<MemoryItem> items,
) async {
  final VolatileMemoryRepository repo = VolatileMemoryRepository();
  await tester.runAsync(() async {
    for (final MemoryItem item in items) {
      await repo.insert(item);
    }
  });
  return repo;
}

void main() {
  testWidgets('memory tab lists approved memories and explains privacy',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final VolatileMemoryRepository repo = await _seeded(tester, <MemoryItem>[
      _item('a', 'I prefer short answers', category: MemoryCategory.preference),
      _item('b', 'Building a timetable app', category: MemoryCategory.project),
      _item('c', 'I am learning Hausa vocabulary',
          category: MemoryCategory.learning, status: MemoryStatus.suggested),
    ]);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openMemory(tester);

    expect(find.text('I prefer short answers'), findsOneWidget);
    expect(find.text('Building a timetable app'), findsOneWidget);
    expect(find.text('I am learning Hausa vocabulary'), findsOneWidget);
    expect(find.text('SUGGESTED BY ALMUS'), findsOneWidget);
    expect(find.textContaining('sent with it to your backend'), findsOneWidget);
  });

  testWidgets('a suggestion can be saved and another dismissed',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final VolatileMemoryRepository repo = await _seeded(tester, <MemoryItem>[
      _item('s1', 'I am learning Hausa vocabulary',
          category: MemoryCategory.learning, status: MemoryStatus.suggested),
      _item('s2', 'I am building a quiz game',
          category: MemoryCategory.project, status: MemoryStatus.suggested),
    ]);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openMemory(tester);

    await tester.tap(find.byKey(const Key('confirm_suggestion_s1')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('reject_suggestion_s2')));
    await _settle(tester);

    final List<MemoryItem> stored =
        (await tester.runAsync(() => repo.list()))!;
    expect(stored.length, 1);
    expect(stored.single.id, 's1');
    expect(stored.single.status, MemoryStatus.confirmed);
    expect(find.byKey(const Key('memory_s1')), findsOneWidget);
  });

  testWidgets('memory can be added manually, and secrets are refused',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final VolatileMemoryRepository repo = VolatileMemoryRepository();
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openMemory(tester);

    await tester.tap(find.byKey(const Key('add_memory_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const Key('memory_text_field')), 'I prefer short answers');
    await tester.tap(find.byKey(const Key('category_preference')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('memory_save_button')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('I prefer short answers'), findsOneWidget);
    List<MemoryItem> stored = (await tester.runAsync(() => repo.list()))!;
    expect(stored.single.category, MemoryCategory.preference);

    await tester.tap(find.byKey(const Key('add_memory_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const Key('memory_text_field')), 'My password is hunter2');
    await tester.tap(find.byKey(const Key('memory_save_button')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('never stores'), findsOneWidget);
    stored = (await tester.runAsync(() => repo.list()))!;
    expect(stored.length, 1);
  });

  testWidgets('the master switch turns memory off and clear all deletes everything',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final VolatileMemoryRepository repo = await _seeded(tester, <MemoryItem>[
      _item('a', 'I prefer short answers', category: MemoryCategory.preference),
    ]);
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await _openMemory(tester);

    await tester.tap(find.byKey(const Key('memory_enabled_switch')));
    await _settle(tester);
    expect((await tester.runAsync(() => repo.isEnabled()))!, isFalse);
    expect(find.textContaining('Off: nothing is retrieved'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('clear_memories_button')));
    await tester.tap(find.byKey(const Key('clear_memories_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('confirm_clear_memories')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect((await tester.runAsync(() => repo.list()))!, isEmpty);
    expect(find.text('No memories yet'), findsOneWidget);
  });

  testWidgets('chat shows the memory switch and offers suggestions',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final VolatileMemoryRepository repo = VolatileMemoryRepository();
    await tester.pumpWidget(_app(repo));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Memory is on'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat_memory_toggle')));
    await tester.pump();
    expect(find.text('Memory is off for this chat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat_memory_toggle')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('chat_input')), 'I am learning Flutter these days.');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('chat_suggestion_text')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat_suggestion_confirm')));
    await _settle(tester);

    final List<MemoryItem> stored = (await tester.runAsync(() => repo.list()))!;
    expect(stored.single.status, MemoryStatus.confirmed);
    expect(stored.single.text, 'I am learning Flutter these days');

    await tester.pump(const Duration(seconds: 8));
  });
}
