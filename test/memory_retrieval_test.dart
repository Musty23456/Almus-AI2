import 'package:almus_ai/models/memory_item.dart';
import 'package:almus_ai/services/memory_retrieval.dart';
import 'package:almus_ai/services/memory_text.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryItem _mem(
  String id,
  String text, {
  MemoryCategory category = MemoryCategory.fact,
  int day = 1,
  MemoryStatus status = MemoryStatus.confirmed,
}) {
  final DateTime t = DateTime(2026, 10, day, 12);
  return MemoryItem(
    id: id,
    category: category,
    text: text,
    createdAt: t,
    updatedAt: t,
    status: status,
  );
}

List<String> _ids(List<RetrievedMemory> r) =>
    r.map((RetrievedMemory m) => m.item.id).toList();

void main() {
  group('text helpers', () {
    test('tokenizing lower-cases, stems and drops stop words', () {
      expect(tokenizeMemory('I am Learning the Flutter widgets!'), <String>['learn', 'flutter', 'widget']);
      expect(tokenizeMemory('The and of'), isEmpty);
    });

    test('tokenizing keeps letters from other alphabets', () {
      expect(tokenizeMemory('Ƙarfi da hikima'), <String>['ƙarfi', 'hikima']);
    });

    test('duplicate detection ignores case, punctuation and filler words', () {
      expect(isDuplicateMemoryText('I prefer short answers', 'i prefer SHORT answers!!'), isTrue);
      expect(isDuplicateMemoryText('I prefer short answers', 'I prefer short answers please'), isTrue);
      expect(isDuplicateMemoryText('I prefer short answers', 'I prefer long detailed answers'), isFalse);
      expect(isDuplicateMemoryText('', 'anything'), isFalse);
    });
  });

  group('retrieval relevance', () {
    final List<MemoryItem> pool = <MemoryItem>[
      _mem('flutter', 'I am learning Flutter and Dart', category: MemoryCategory.learning),
      _mem('food', 'My favourite food is jollof rice'),
      _mem('style', 'I prefer short answers', category: MemoryCategory.preference),
    ];

    test('returns memories that share topic words with the message', () {
      final List<RetrievedMemory> r = retrieveMemories(
        query: 'Can you help me with a Flutter widget?',
        candidates: pool,
      );
      expect(_ids(r), <String>['flutter']);
    });

    test('an unrelated message retrieves nothing', () {
      expect(
        retrieveMemories(query: 'What is the capital of France?', candidates: pool),
        isEmpty,
      );
    });

    test('an empty pool or empty message retrieves nothing', () {
      expect(retrieveMemories(query: 'flutter', candidates: const <MemoryItem>[]), isEmpty);
      expect(retrieveMemories(query: '   ', candidates: pool), isEmpty);
    });

    test('the better match comes first and weak matches are dropped', () {
      final List<RetrievedMemory> r = retrieveMemories(
        query: 'Tell me about the Almus AI Flutter project',
        candidates: <MemoryItem>[
          _mem('a', 'I am learning Flutter', category: MemoryCategory.learning),
          _mem('b', 'Almus AI is my Flutter project', category: MemoryCategory.project),
        ],
      );
      expect(_ids(r).first, 'b');
      expect(_ids(r), isNot(contains('c')));

      final List<RetrievedMemory> both = retrieveMemories(
        query: 'Flutter widgets notes',
        candidates: <MemoryItem>[
          _mem('x', 'Flutter widgets notes from class'),
          _mem('y', 'Flutter widgets'),
        ],
      );
      expect(both.length, 2);
      expect(both.first.score, greaterThanOrEqualTo(both.last.score));
    });

    test('unconfirmed suggestions are never retrieved', () {
      final List<RetrievedMemory> r = retrieveMemories(
        query: 'Flutter question',
        candidates: <MemoryItem>[
          _mem('s', 'I am learning Flutter', status: MemoryStatus.suggested),
        ],
      );
      expect(r, isEmpty);
    });

    test('at most maxItems come back, and at most maxSummaries are summaries', () {
      final List<MemoryItem> many = <MemoryItem>[
        for (int i = 0; i < 4; i++)
          _mem('sum$i', 'Chat about Flutter widgets part $i', category: MemoryCategory.summary, day: 1 + i),
        for (int i = 0; i < 4; i++) _mem('fact$i', 'Flutter widgets fact number $i', day: 10 + i),
      ];
      final List<RetrievedMemory> r = retrieveMemories(
        query: 'Flutter widgets',
        candidates: many,
        maxItems: 5,
        maxSummaries: 2,
      );
      expect(r.length, 5);
      expect(
        r.where((RetrievedMemory m) => m.item.category == MemoryCategory.summary).length,
        lessThanOrEqualTo(2),
      );
    });

    test('a short follow-up borrows the topic of the previous message', () {
      final List<MemoryItem> hausa = <MemoryItem>[
        _mem('h', 'Learning Hausa vocabulary', category: MemoryCategory.learning),
      ];
      expect(retrieveMemories(query: 'yes please do that', candidates: hausa), isEmpty);
      expect(
        _ids(retrieveMemories(
          query: 'yes please do that',
          candidates: hausa,
          previousUserText: 'Teach me Hausa vocabulary',
        )),
        <String>['h'],
      );
    });

    test('"continue" brings back the most recent open work', () {
      final List<RetrievedMemory> r = retrieveMemories(
        query: 'Let us continue where we stopped',
        candidates: <MemoryItem>[
          _mem('old', 'Building a school timetable app', category: MemoryCategory.project, day: 1),
          _mem('new', 'Writing a Hausa phrasebook', category: MemoryCategory.project, day: 9),
          _mem('tea', 'I like tea in the morning', day: 12),
        ],
      );
      expect(_ids(r).toSet(), <String>{'old', 'new'});
    });

    test('hasContinueIntent recognises common phrases', () {
      expect(hasContinueIntent('Please continue the project'), isTrue);
      expect(hasContinueIntent('Where did we stop?'), isTrue);
      expect(hasContinueIntent('where were we?'), isTrue);
      expect(hasContinueIntent('What is the weather?'), isFalse);
    });
  });

  group('context construction', () {
    RetrievedMemory pick(MemoryItem item, [double score = 1]) => RetrievedMemory(item, score);

    test('nothing to send gives null', () {
      expect(buildMemoryContext(const <RetrievedMemory>[]), isNull);
    });

    test('confirmed facts and approximate summaries are kept apart', () {
      final String text = buildMemoryContext(<RetrievedMemory>[
        pick(_mem('p', 'I prefer short answers', category: MemoryCategory.preference)),
        pick(_mem('s', 'Chat about the timetable app', category: MemoryCategory.summary, day: 12)),
      ])!;
      expect(text, startsWith('LOCAL MEMORY NOTES'));
      expect(text, contains('Confirmed by the user:'));
      expect(text, contains('- [preference] I prefer short answers'));
      expect(text, contains('Approximate summaries of earlier chats'));
      expect(text, contains('- [summary 2026-10-12] Chat about the timetable app'));
      expect(
        text.indexOf('Confirmed by the user:'),
        lessThan(text.indexOf('Approximate summaries')),
      );
    });

    test('a block with only facts has no summary section', () {
      final String text = buildMemoryContext(<RetrievedMemory>[
        pick(_mem('p', 'I prefer short answers', category: MemoryCategory.preference)),
      ])!;
      expect(text, isNot(contains('Approximate summaries')));
    });

    test('the AI is told not to invent or pretend to remember', () {
      final String text = buildMemoryContext(<RetrievedMemory>[pick(_mem('a', 'I live in Kano'))])!;
      expect(text, contains('must not pretend'));
      expect(text, contains('trust the user'));
    });

    test('the block never exceeds the limit and drops the lowest ranked first', () {
      final List<RetrievedMemory> ranked = <RetrievedMemory>[
        pick(_mem('a', 'A' * 250)),
        pick(_mem('b', 'B' * 250)),
        pick(_mem('c', 'C' * 250)),
      ];
      final String text = buildMemoryContext(ranked, maxChars: 700)!;
      expect(text.length, lessThanOrEqualTo(700));
      expect(text, contains('A' * 250));
      expect(text, isNot(contains('B' * 250)));
      expect(text, isNot(contains('C' * 250)));
    });

    test('a very long memory is shortened', () {
      final String text = buildMemoryContext(
        <RetrievedMemory>[pick(_mem('a', 'X' * 400))],
        maxItemChars: 50,
      )!;
      expect(text, contains('X' * 50));
      expect(text, isNot(contains('X' * 51)));
      expect(text, contains('…'));
    });

    test('worst-case input still fits the default limit', () {
      final List<RetrievedMemory> big = <RetrievedMemory>[
        for (int i = 0; i < kMemoryMaxItems; i++) pick(_mem('m$i', '${'Z' * kMaxMemoryChars}$i')),
      ];
      final String text = buildMemoryContext(big)!;
      expect(text.length, lessThanOrEqualTo(kMemoryContextMaxChars));
    });

    test('retrieval plus context sends only the relevant few of many memories', () {
      final List<MemoryItem> many = <MemoryItem>[
        for (int i = 0; i < 60; i++) _mem('m$i', 'Unrelated note number $i about gardening topic$i'),
        _mem('target', 'I am building a school timetable app', category: MemoryCategory.project),
      ];
      final List<RetrievedMemory> picked =
          retrieveMemories(query: 'Help with my timetable app', candidates: many);
      expect(_ids(picked), <String>['target']);
      final String text = buildMemoryContext(picked)!;
      expect(text, contains('school timetable app'));
      expect(text, isNot(contains('gardening')));
      expect(text.length, lessThanOrEqualTo(kMemoryContextMaxChars));
    });
  });
}
