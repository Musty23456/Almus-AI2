import 'package:almus_ai/data/memory_repository.dart';
import 'package:almus_ai/data/storage_exception.dart';
import 'package:almus_ai/models/memory_item.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryItem memoryItem(
  String id, {
  MemoryCategory category = MemoryCategory.fact,
  String text = 'Some text',
  int minute = 0,
  MemoryStatus status = MemoryStatus.confirmed,
  String? source,
}) {
  final DateTime t = DateTime(2026, 1, 1, 10, minute);
  return MemoryItem(
    id: id,
    category: category,
    text: text,
    createdAt: t,
    updatedAt: t,
    sourceConversationId: source,
    status: status,
  );
}

/// Behaviour every [MemoryRepository] implementation must share.
void runMemoryRepositoryContract(
  String name,
  Future<MemoryRepository> Function() create, {
  Future<void> Function()? dispose,
}) {
  group('$name memory repository contract', () {
    late MemoryRepository repo;

    setUp(() async {
      repo = await create();
    });

    tearDown(() async {
      await dispose?.call();
    });

    test('inserts a record and reads back every field', () async {
      await repo.insert(memoryItem(
        'a',
        category: MemoryCategory.project,
        text: 'Building a timetable app',
        minute: 5,
        status: MemoryStatus.suggested,
        source: 'c1',
      ));
      final MemoryItem? item = await repo.get('a');
      expect(item, isNotNull);
      expect(item!.category, MemoryCategory.project);
      expect(item.text, 'Building a timetable app');
      expect(item.createdAt, DateTime(2026, 1, 1, 10, 5));
      expect(item.updatedAt, DateTime(2026, 1, 1, 10, 5));
      expect(item.sourceConversationId, 'c1');
      expect(item.status, MemoryStatus.suggested);
      expect(await repo.get('missing'), isNull);
    });

    test('a record without a source conversation stays without one', () async {
      await repo.insert(memoryItem('a'));
      expect((await repo.get('a'))!.sourceConversationId, isNull);
    });

    test('inserting the same id twice fails', () async {
      await repo.insert(memoryItem('a'));
      expect(
        repo.insert(memoryItem('a', text: 'Other')),
        throwsA(isA<StorageException>()),
      );
    });

    test('lists newest update first and filters by status and category', () async {
      await repo.insert(memoryItem('old', minute: 1, category: MemoryCategory.goal));
      await repo.insert(memoryItem('new', minute: 9, category: MemoryCategory.fact));
      await repo.insert(memoryItem(
        'sug',
        minute: 5,
        category: MemoryCategory.goal,
        status: MemoryStatus.suggested,
      ));

      expect(
        (await repo.list()).map((MemoryItem m) => m.id),
        <String>['new', 'sug', 'old'],
      );
      expect(
        (await repo.list(status: MemoryStatus.suggested)).map((MemoryItem m) => m.id),
        <String>['sug'],
      );
      expect(
        (await repo.list(category: MemoryCategory.goal)).map((MemoryItem m) => m.id),
        <String>['sug', 'old'],
      );
      expect(
        (await repo.list(
          category: MemoryCategory.goal,
          status: MemoryStatus.confirmed,
        ))
            .map((MemoryItem m) => m.id),
        <String>['old'],
      );
    });

    test('update replaces the record and fails for a missing one', () async {
      await repo.insert(memoryItem('a', text: 'Before'));
      final MemoryItem current = (await repo.get('a'))!;
      await repo.update(current.copyWith(
        text: 'After',
        category: MemoryCategory.learning,
        status: MemoryStatus.suggested,
        updatedAt: DateTime(2026, 2, 2),
      ));
      final MemoryItem changed = (await repo.get('a'))!;
      expect(changed.text, 'After');
      expect(changed.category, MemoryCategory.learning);
      expect(changed.status, MemoryStatus.suggested);
      expect(changed.updatedAt, DateTime(2026, 2, 2));
      expect(changed.createdAt, current.createdAt);

      expect(
        repo.update(memoryItem('missing')),
        throwsA(isA<StorageException>()),
      );
    });

    test('delete reports whether a record was removed', () async {
      await repo.insert(memoryItem('a'));
      expect(await repo.delete('a'), isTrue);
      expect(await repo.delete('a'), isFalse);
      expect(await repo.get('a'), isNull);
    });

    test('clearAll removes memories but keeps the switches', () async {
      await repo.insert(memoryItem('a'));
      await repo.insert(memoryItem('b', status: MemoryStatus.suggested));
      await repo.setEnabled(false);
      await repo.setConversationMemoryOff('c1', true);

      await repo.clearAll();

      expect(await repo.list(), isEmpty);
      expect(await repo.isEnabled(), isFalse);
      expect(await repo.isConversationMemoryOff('c1'), isTrue);
    });

    test('memory is enabled by default and the switch can be changed', () async {
      expect(await repo.isEnabled(), isTrue);
      await repo.setEnabled(false);
      expect(await repo.isEnabled(), isFalse);
      await repo.setEnabled(true);
      expect(await repo.isEnabled(), isTrue);
    });

    test('memory can be switched off per conversation', () async {
      expect(await repo.isConversationMemoryOff('c1'), isFalse);
      await repo.setConversationMemoryOff('c1', true);
      await repo.setConversationMemoryOff('c1', true);
      expect(await repo.isConversationMemoryOff('c1'), isTrue);
      expect(await repo.isConversationMemoryOff('c2'), isFalse);
      await repo.setConversationMemoryOff('c1', false);
      expect(await repo.isConversationMemoryOff('c1'), isFalse);

      await repo.setConversationMemoryOff('c1', true);
      await repo.setConversationMemoryOff('c2', true);
      await repo.clearConversationFlags();
      expect(await repo.isConversationMemoryOff('c1'), isFalse);
      expect(await repo.isConversationMemoryOff('c2'), isFalse);
    });
  });
}
