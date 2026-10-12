import 'package:almus_ai/models/memory_item.dart';
import 'package:almus_ai/services/memory_extractor.dart';
import 'package:almus_ai/services/sensitive_filter.dart';
import 'package:flutter_test/flutter_test.dart';

MemorySuggestion _one(String message) {
  final List<MemorySuggestion> found = extractMemorySuggestions(message);
  expect(found.length, 1, reason: message);
  return found.single;
}

void main() {
  group('suggestions from messages', () {
    test('explicit "remember that" keeps only the fact', () {
      final MemorySuggestion s = _one('Please remember that I prefer short answers.');
      expect(s.text, 'I prefer short answers');
      expect(s.category, MemoryCategory.preference);
    });

    test('recognises profile, learning, project and goal statements', () {
      expect(_one('My name is Musty').category, MemoryCategory.profile);
      expect(_one('I am learning Flutter these days.').category, MemoryCategory.learning);
      expect(_one('I am building a school timetable app').category, MemoryCategory.project);
      expect(
        _one('My goal is to finish the Flutter course by December.').category,
        MemoryCategory.goal,
      );
    });

    test('recognises some Hausa phrases', () {
      expect(_one('Sunana Musty Salisu').category, MemoryCategory.profile);
      expect(_one('Ina koyon harshen Turanci').category, MemoryCategory.learning);
    });

    test('an explicit request with no pattern becomes an approved-fact suggestion', () {
      final MemorySuggestion s = _one('Remember that the meeting is at noon on Fridays');
      expect(s.category, MemoryCategory.fact);
      expect(s.text, 'the meeting is at noon on Fridays');
    });

    test('ignores questions, requests and small talk', () {
      expect(extractMemorySuggestions('What is the capital of France?'), isEmpty);
      expect(extractMemorySuggestions('I like your answer, thanks.'), isEmpty);
      expect(extractMemorySuggestions('I want to know the weather today.'), isEmpty);
      expect(extractMemorySuggestions('Remember to buy milk'), isEmpty);
      expect(extractMemorySuggestions('Do you know what I am building?'), isEmpty);
      expect(extractMemorySuggestions('hello'), isEmpty);
    });

    test('never proposes sensitive topics or secrets', () {
      expect(extractMemorySuggestions('I prefer to discuss my diabetes treatment.'), isEmpty);
      expect(extractMemorySuggestions('Remember that my password is hunter2'), isEmpty);
      expect(extractMemorySuggestions('I live at 12 Example Street, my home address.'), isEmpty);
    });

    test('proposes at most two per message and no repeats', () {
      final List<MemorySuggestion> found = extractMemorySuggestions(
        'I am learning Flutter. I am building a timetable app. My goal is to publish it soon.',
      );
      expect(found.length, 2);
      expect(
        extractMemorySuggestions('I am learning Flutter. I am learning Flutter.').length,
        1,
      );
    });
  });

  group('sensitivity check', () {
    test('plain text is fine', () {
      expect(checkSensitivity('I prefer short answers').level, Sensitivity.none);
      expect(checkSensitivity('Building a school timetable app').level, Sensitivity.none);
    });

    test('personal topics are sensitive', () {
      for (final String text in <String>[
        'I was diagnosed with asthma',
        'I am a Muslim',
        'I voted in the election',
        'My salary is low',
        'I have a lawsuit pending',
      ]) {
        expect(checkSensitivity(text).level, Sensitivity.sensitive, reason: text);
      }
    });

    test('secrets and numbers are blocked', () {
      for (final String text in <String>[
        'my password is abc',
        'card 4111-1111-1111-1111',
        'ssn 123-45-6789',
        'my BVN is 12345678901',
        'key sk-abcdefghijklmnopqrstuvwxyz',
      ]) {
        expect(checkSensitivity(text).level, Sensitivity.blocked, reason: text);
      }
    });

    test('words that only look similar are not flagged', () {
      expect(checkSensitivity('I enjoy gaya in Hausa lessons').level, Sensitivity.none);
      expect(checkSensitivity('Phone 08012345678').level, Sensitivity.none);
    });
  });

  group('chat summary draft', () {
    test('mentions the title, size, first and latest user message', () {
      final String draft = draftConversationSummary(
        title: 'Flutter tips',
        userMessages: <String>['How do I use sqflite?', 'Thanks, now explain migrations'],
        messageCount: 6,
        date: DateTime(2026, 10, 12),
      );
      expect(draft, contains('"Flutter tips"'));
      expect(draft, contains('12 Oct 2026'));
      expect(draft, contains('6 messages'));
      expect(draft, contains('How do I use sqflite?'));
      expect(draft, contains('now explain migrations'));
    });

    test('a long message is shortened and an empty chat still gives a draft', () {
      final String long = draftConversationSummary(
        title: 'T',
        userMessages: <String>['word ' * 200],
        messageCount: 1,
        date: DateTime(2026, 1, 1),
      );
      expect(long.length, lessThan(400));
      expect(long, contains('…'));

      final String empty = draftConversationSummary(
        title: 'Empty',
        userMessages: const <String>[],
        messageCount: 0,
        date: DateTime(2026, 1, 1),
      );
      expect(empty, contains('"Empty"'));
    });
  });
}
