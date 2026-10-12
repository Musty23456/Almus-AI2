import 'package:almus_ai/controllers/memory_controller.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/data/volatile_memory_repository.dart';
import 'package:almus_ai/models/memory_item.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_repository_contract.dart';

class _ListFails extends VolatileMemoryRepository {
  @override
  Future<List<MemoryItem>> list({
    MemoryStatus? status,
    MemoryCategory? category,
  }) async {
    throw const StorageException('The local database reported an error.');
  }
}

void main() {
  late VolatileMemoryRepository repo;
  late DateTime clock;
  late MemoryController memory;

  setUp(() {
    repo = VolatileMemoryRepository();
    clock = DateTime(2026, 10, 12, 9);
    memory = MemoryController(repo, now: () => clock);
  });

  tearDown(() => memory.dispose());

  group('creation and editing', () {
    test('creates a confirmed memory with id, dates and source', () async {
      final MemorySaveResult result = await memory.add(
        category: MemoryCategory.preference,
        text: '  I prefer   short answers ',
        sourceConversationId: 'c1',
      );
      expect(result.isSaved, isTrue);
      final MemoryItem item = result.item!;
      expect(item.id, isNotEmpty);
      expect(item.text, 'I prefer short answers');
      expect(item.category, MemoryCategory.preference);
      expect(item.createdAt, clock);
      expect(item.updatedAt, clock);
      expect(item.sourceConversationId, 'c1');
      expect(item.status, MemoryStatus.confirmed);
      expect(memory.items.single.id, item.id);
      expect((await repo.list()).single.text, 'I prefer short answers');
    });

    test('every memory gets a different id', () async {
      final MemorySaveResult a =
          await memory.add(category: MemoryCategory.fact, text: 'Alpha beta gamma');
      final MemorySaveResult b =
          await memory.add(category: MemoryCategory.fact, text: 'Delta epsilon zeta');
      expect(a.item!.id, isNot(b.item!.id));
    });

    test('editing changes text and category, bumps updatedAt, keeps createdAt',
        () async {
      final MemoryItem original = (await memory.add(
        category: MemoryCategory.goal,
        text: 'Finish the Flutter course',
      ))
          .item!;
      clock = clock.add(const Duration(days: 2));

      final MemorySaveResult result = await memory.edit(
        original.id,
        category: MemoryCategory.learning,
        text: 'Finish the Flutter course by December',
      );

      expect(result.isSaved, isTrue);
      final MemoryItem edited = (await repo.get(original.id))!;
      expect(edited.text, 'Finish the Flutter course by December');
      expect(edited.category, MemoryCategory.learning);
      expect(edited.createdAt, original.createdAt);
      expect(edited.updatedAt, clock);
      expect(edited.status, MemoryStatus.confirmed);
    });

    test('editing a memory that does not exist fails cleanly', () async {
      final MemorySaveResult result = await memory.edit('nope', text: 'Anything here');
      expect(result.status, MemorySaveStatus.failed);
    });

    test('empty and too long text are refused', () async {
      expect(
        (await memory.add(category: MemoryCategory.fact, text: '   ')).status,
        MemorySaveStatus.empty,
      );
      expect(
        (await memory.add(
          category: MemoryCategory.fact,
          text: 'a' * (kMaxMemoryChars + 1),
        ))
            .status,
        MemorySaveStatus.tooLong,
      );
      expect(memory.items, isEmpty);
    });

    test('load restores memories and the master switch from storage', () async {
      await repo.insert(memoryItem('a', text: 'Stored earlier'));
      await repo.setEnabled(false);
      final MemoryController fresh = MemoryController(repo);
      await fresh.load();
      expect(fresh.items.single.text, 'Stored earlier');
      expect(fresh.enabled, isFalse);
      fresh.dispose();
    });

    test('storage failures are reported without throwing', () async {
      final MemoryController broken = MemoryController(_ListFails());
      await broken.load();
      expect(broken.error, isNotNull);
      expect(broken.items, isEmpty);
      broken.dispose();
    });
  });

  group('deletion', () {
    test('delete removes one memory', () async {
      final MemoryItem a =
          (await memory.add(category: MemoryCategory.fact, text: 'Alpha beta gamma')).item!;
      await memory.add(category: MemoryCategory.fact, text: 'Delta epsilon zeta');

      expect(await memory.delete(a.id), isTrue);

      expect(memory.items.length, 1);
      expect(memory.items.single.text, 'Delta epsilon zeta');
      expect(await repo.get(a.id), isNull);
    });

    test('clearAll removes memories and pending suggestions', () async {
      await memory.add(category: MemoryCategory.fact, text: 'Alpha beta gamma');
      await memory.suggestFrom('I am learning Flutter these days.');
      expect(memory.items.length, 2);

      expect(await memory.clearAll(), isTrue);

      expect(memory.items, isEmpty);
      expect(await repo.list(), isEmpty);
    });
  });

  group('duplicates', () {
    test('a near-identical memory is refused', () async {
      await memory.add(category: MemoryCategory.preference, text: 'I prefer short answers');
      final MemorySaveResult again = await memory.add(
        category: MemoryCategory.preference,
        text: 'i prefer SHORT answers!!',
      );
      expect(again.status, MemorySaveStatus.duplicate);
      expect(memory.items.length, 1);
    });

    test('different memories are both kept', () async {
      await memory.add(category: MemoryCategory.preference, text: 'I prefer short answers');
      final MemorySaveResult other = await memory.add(
        category: MemoryCategory.project,
        text: 'Building a school timetable app',
      );
      expect(other.isSaved, isTrue);
      expect(memory.items.length, 2);
    });

    test('editing into a copy of another memory is refused, but keeping your own text is fine',
        () async {
      final MemoryItem a = (await memory.add(
        category: MemoryCategory.fact,
        text: 'Almus is my personal assistant app',
      ))
          .item!;
      final MemoryItem b = (await memory.add(
        category: MemoryCategory.fact,
        text: 'I live in Kano city',
      ))
          .item!;

      expect(
        (await memory.edit(b.id, text: 'Almus is my personal assistant app')).status,
        MemorySaveStatus.duplicate,
      );
      expect(
        (await memory.edit(a.id, category: MemoryCategory.project)).isSaved,
        isTrue,
      );
    });

    test('suggestions already saved or already suggested are not repeated',
        () async {
      await memory.add(category: MemoryCategory.learning, text: 'I am learning Flutter these days');
      expect(await memory.suggestFrom('I am learning Flutter these days.'), isEmpty);

      final List<MemoryItem> first =
          await memory.suggestFrom('I am studying Dart every evening.');
      expect(first.length, 1);
      expect(await memory.suggestFrom('I am studying Dart every evening.'), isEmpty);
      expect(memory.suggestions.length, 1);
    });
  });

  group('sensitive information', () {
    test('sensitive text is never saved without explicit confirmation', () async {
      final MemorySaveResult first = await memory.add(
        category: MemoryCategory.fact,
        text: 'I take medication for diabetes',
      );
      expect(first.status, MemorySaveStatus.needsConfirmation);
      expect(memory.items, isEmpty);
      expect(await repo.list(), isEmpty);

      final MemorySaveResult second = await memory.add(
        category: MemoryCategory.fact,
        text: 'I take medication for diabetes',
        allowSensitive: true,
      );
      expect(second.isSaved, isTrue);
    });

    test('secrets and card numbers are never stored, even when allowed', () async {
      for (final String text in <String>[
        'My password is hunter2',
        'My card is 4111 1111 1111 1111',
        'api key AIzaSyA1234567890abcdefghijklmnop',
      ]) {
        final MemorySaveResult result = await memory.add(
          category: MemoryCategory.fact,
          text: text,
          allowSensitive: true,
        );
        expect(result.status, MemorySaveStatus.blocked, reason: text);
      }
      expect(memory.items, isEmpty);
    });

    test('editing a memory into a secret is blocked', () async {
      final MemoryItem a =
          (await memory.add(category: MemoryCategory.fact, text: 'Alpha beta gamma')).item!;
      final MemorySaveResult result = await memory.edit(
        a.id,
        text: 'My password is hunter2',
        allowSensitive: true,
      );
      expect(result.status, MemorySaveStatus.blocked);
      expect((await repo.get(a.id))!.text, 'Alpha beta gamma');
    });

    test('Almus never suggests sensitive topics, questions or small talk', () async {
      expect(await memory.suggestFrom('I prefer to talk about my diabetes.'), isEmpty);
      expect(await memory.suggestFrom('My password is hunter2 and I prefer it.'), isEmpty);
      expect(await memory.suggestFrom('Do you know what I prefer for dinner?'), isEmpty);
      expect(await memory.suggestFrom('I like your answer, thanks.'), isEmpty);
      expect(memory.items, isEmpty);
    });
  });

  group('suggestions', () {
    test('a suggestion is not a confirmed memory and is not used until confirmed',
        () async {
      final List<MemoryItem> created =
          await memory.suggestFrom('I am learning Flutter these days.');
      expect(created.single.status, MemoryStatus.suggested);
      expect(created.single.category, MemoryCategory.learning);
      expect(memory.confirmed, isEmpty);
      expect(memory.suggestions.length, 1);
      expect((await memory.contextFor('How is my Flutter learning going?')).text, isNull);

      final MemorySaveResult result = await memory.confirm(created.single.id);
      expect(result.isSaved, isTrue);
      expect(memory.suggestions, isEmpty);
      expect(memory.confirmed.length, 1);
      expect(
        (await memory.contextFor('How is my Flutter learning going?')).text,
        contains('learning Flutter'),
      );
    });

    test('rejecting a suggestion deletes it', () async {
      final MemoryItem s =
          (await memory.suggestFrom('I am learning Flutter these days.')).single;
      expect(await memory.reject(s.id), isTrue);
      expect(memory.items, isEmpty);
      expect(await repo.list(), isEmpty);
    });

    test('a suggestion remembers the chat it came from', () async {
      final MemoryItem s = (await memory.suggestFrom(
        'I am learning Flutter these days.',
        conversationId: 'c42',
      ))
          .single;
      expect(s.sourceConversationId, 'c42');
    });

    test('confirming a suggestion that looks sensitive asks first', () async {
      await repo.insert(memoryItem(
        'x',
        text: 'I take medication every morning',
        status: MemoryStatus.suggested,
      ));
      await memory.load();
      expect((await memory.confirm('x')).status, MemorySaveStatus.needsConfirmation);
      expect(memory.confirmed, isEmpty);
      expect((await memory.confirm('x', allowSensitive: true)).isSaved, isTrue);
    });
  });

  group('disabled memory mode', () {
    test('nothing is suggested or retrieved while memory is off', () async {
      await memory.add(category: MemoryCategory.project, text: 'Building a school timetable app');
      expect(await memory.setEnabled(false), isTrue);
      expect(memory.enabled, isFalse);
      expect(await repo.isEnabled(), isFalse);

      expect(await memory.suggestFrom('I am learning Flutter these days.'), isEmpty);
      expect(memory.suggestions, isEmpty);
      final MemoryContext context = await memory.contextFor('How is my timetable app?');
      expect(context.text, isNull);
      expect(context.used, isEmpty);

      // Saved memories stay visible and can be managed.
      expect(memory.confirmed.length, 1);
    });

    test('turning memory back on restores retrieval', () async {
      await memory.add(category: MemoryCategory.project, text: 'Building a school timetable app');
      await memory.setEnabled(false);
      await memory.setEnabled(true);
      final MemoryContext context = await memory.contextFor('How is my timetable app?');
      expect(context.text, contains('school timetable app'));
      expect(context.used.length, 1);
    });

    test('memory can be off for a single chat only', () async {
      await memory.add(category: MemoryCategory.project, text: 'Building a school timetable app');
      expect(
        (await memory.contextFor('How is my timetable app?', chatMemoryOff: true)).text,
        isNull,
      );
      expect(
        (await memory.contextFor('How is my timetable app?')).text,
        isNotNull,
      );
    });

    test('per-chat switches are stored and can be forgotten', () async {
      expect(await memory.isConversationOff('c1'), isFalse);
      expect(await memory.setConversationOff('c1', true), isTrue);
      expect(await memory.isConversationOff('c1'), isTrue);
      await memory.forgetConversationFlags();
      expect(await memory.isConversationOff('c1'), isFalse);
    });
  });
}
