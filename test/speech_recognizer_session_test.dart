import 'dart:async';

import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_engine_fake.dart';

Future<void> wait([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Collects what one session reports.
class Session {
  final List<(String, bool)> texts = <(String, bool)>[];
  final List<RecognizerProblem> problems = <RecognizerProblem>[];
  int done = 0;
  int listening = 0;
}

Future<Session> begin(PlatformSpeechRecognizer r, [String locale = 'en_US']) async {
  final Session s = Session();
  await r.start(
    localeId: locale,
    onText: (String t, bool f) => s.texts.add((t, f)),
    onProblem: s.problems.add,
    onDone: () => s.done++,
    onListening: () => s.listening++,
  );
  return s;
}

PlatformSpeechRecognizer make(FakeSpeechEngine e, {int startMs = 300, int graceMs = 60}) =>
    PlatformSpeechRecognizer(
      engine: e,
      startTimeout: Duration(milliseconds: startMs),
      finalGrace: Duration(milliseconds: graceMs),
    );

void main() {
  group('prepare (permission, engine, language)', () {
    test('ready with the matching locale', () async {
      final PlatformSpeechRecognizer r = make(FakeSpeechEngine());
      final RecognizerInit init = await r.prepare(VoiceLanguage.english);
      expect(init.problem, isNull);
      expect(init.localeId, 'en_US');
    });

    test('permission denied is reported and the lookup retry is not attempted', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()
        ..initResults = <bool>[false]
        ..permission = false;
      final RecognizerInit init = await make(e).prepare(VoiceLanguage.english);
      expect(init.problem, RecognizerProblem.permissionDenied);
      expect(e.initCalls, 1);
    });

    test('engine missing: retries once with the intent lookup, then reports unavailable', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()..initResults = <bool>[false];
      final RecognizerInit init = await make(e).prepare(VoiceLanguage.english);
      expect(init.problem, RecognizerProblem.unavailable);
      expect(e.intentLookups, <bool>[false, true]);
    });

    test('the intent-lookup retry can rescue a phone where the first lookup fails', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()..initResults = <bool>[false, true];
      final RecognizerInit init = await make(e).prepare(VoiceLanguage.english);
      expect(init.problem, isNull);
    });

    test('Hausa not offered by the engine is reported, never replaced by English', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()..locales = <String>['en_US', 'fr_FR'];
      final RecognizerInit init = await make(e).prepare(VoiceLanguage.hausa);
      expect(init.problem, RecognizerProblem.languageUnsupported);
    });

    test('an engine that lists no languages: English uses its default, Hausa is only attempted', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()..locales = <String>[];
      final PlatformSpeechRecognizer r = make(e);
      expect((await r.prepare(VoiceLanguage.english)).localeId, '');
      expect((await r.prepare(VoiceLanguage.hausa)).localeId, 'ha-NG');
    });

    test('initialize throwing is treated as unavailable', () async {
      final _Throwing e = _Throwing();
      final RecognizerInit init = await make(e).prepare(VoiceLanguage.english);
      expect(init.problem, RecognizerProblem.unavailable);
    });
  });

  group('session lifecycle', () {
    test('final result that arrives AFTER notListening is not lost', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      await r.prepare(VoiceLanguage.english);
      final Session s = await begin(r);
      e.status('listening');
      e.result('sannu', isFinal: false);
      e.status('notListening'); // Android says this before the final result
      await wait(10);
      expect(s.done, 0, reason: 'must still wait for the final result');
      e.result('sannu Almus', isFinal: true);
      expect(s.texts.last, ('sannu Almus', true));
      expect(s.done, 1);
      e.status('done'); // late status must not end anything twice
      await wait(100);
      expect(s.done, 1);
    });

    test('no final result: the session still ends after the grace time and keeps the partial text', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      await begin(r).then((Session s) async {
        e.status('listening');
        e.result('abc');
        e.status('done');
        await wait(150);
        expect(s.done, 1);
        expect(s.problems, isEmpty);
        expect(s.texts.last.$1, 'abc');
      });
    });

    test('a stale "done" from a cancelled session does not end the next session', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      final Session first = await begin(r);
      e.status('listening');
      await r.cancel();
      final Session second = await begin(r);
      e.status('done'); // belongs to the first session
      e.status('notListening');
      await wait(120);
      expect(second.done, 0, reason: 'stale status must be ignored');
      e.status('listening');
      e.result('hello', isFinal: true);
      expect(second.texts.last, ('hello', true));
      expect(second.done, 1);
      expect(first.done, 0, reason: 'a cancelled session reports nothing');
    });

    test('an engine that never starts listening produces a clear problem and is cancelled', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e, startMs: 80);
      final Session s = await begin(r);
      await wait(200);
      expect(s.problems, <RecognizerProblem>[RecognizerProblem.notStarted]);
      expect(s.done, 1);
      expect(e.cancelCalls, greaterThan(0));
    });

    test('onListening fires once when the engine really starts', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      final Session s = await begin(r);
      expect(s.listening, 0);
      e.status('listening');
      e.status('listening');
      expect(s.listening, 2); // controller ignores repeats; the recognizer just forwards
      await r.cancel();
    });

    test('engine errors map to problems and end the session once', () async {
      for (final (String, RecognizerProblem) c in <(String, RecognizerProblem)>[
        ('error_no_match', RecognizerProblem.noSpeech),
        ('error_speech_timeout', RecognizerProblem.noSpeech),
        ('error_insufficient_permissions', RecognizerProblem.permissionDenied),
        ('error_network', RecognizerProblem.network),
        ('error_recognizer_busy', RecognizerProblem.busy),
        ('error_language_not_supported', RecognizerProblem.languageUnsupported),
        ('error_client', RecognizerProblem.other),
      ]) {
        final FakeSpeechEngine e = FakeSpeechEngine();
        final PlatformSpeechRecognizer r = make(e);
        final Session s = await begin(r);
        e.status('listening');
        e.error(c.$1);
        e.error(c.$1); // duplicate error callbacks are ignored
        expect(s.problems, <RecognizerProblem>[c.$2], reason: c.$1);
        expect(s.done, 1, reason: c.$1);
      }
    });

    test('errors that arrive after cancel are ignored (no stray messages)', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      final Session s = await begin(r);
      e.status('listening');
      await r.cancel();
      e.error('error_client');
      e.result('late words', isFinal: true);
      expect(s.problems, isEmpty);
      expect(s.texts, isEmpty);
      expect(s.done, 0);
    });

    test('listen() throwing ends the session with a problem', () async {
      final FakeSpeechEngine e = FakeSpeechEngine()..throwOnListen = true;
      final Session s = await begin(make(e));
      expect(s.problems, <RecognizerProblem>[RecognizerProblem.other]);
      expect(s.done, 1);
    });

    test('a quick second tap cancels a session that is still winding down first', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      await begin(r);
      expect(e.listening, isTrue);
      await begin(r); // engine still "listening" from the first
      expect(e.cancelCalls, greaterThan(0));
      expect(e.listenCalls, 2);
    });

    test('three voice sessions in a row each finish exactly once', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = make(e);
      for (int i = 0; i < 3; i++) {
        final Session s = await begin(r);
        e.status('listening');
        e.result('words $i', isFinal: true);
        e.status('done');
        await wait(100);
        expect(s.done, 1, reason: 'session $i');
        expect(s.texts.last, ('words $i', true));
      }
      expect(e.listenCalls, 3);
    });

    test('empty locale id means the engine default', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      await begin(make(e), '');
      expect(e.lastLocale, isNull);
    });

    test('stop() waits for the last words, then ends even if the engine stays silent', () async {
      final FakeSpeechEngine e = FakeSpeechEngine();
      final PlatformSpeechRecognizer r = PlatformSpeechRecognizer(
        engine: e,
        startTimeout: const Duration(seconds: 5),
        finalGrace: const Duration(milliseconds: 40),
      );
      final Session s = await begin(r);
      e.status('listening');
      e.result('partial');
      await r.stop();
      expect(e.stopCalls, 1);
      e.status('notListening');
      await wait(120);
      expect(s.done, 1);
    });
  });

  group('locale and error helpers', () {
    test('pickLocale prefers the phone language, never crosses languages', () {
      expect(PlatformSpeechRecognizer.pickLocale(VoiceLanguage.english, <String>['en-GB', 'en-US']), 'en-US');
      expect(PlatformSpeechRecognizer.pickLocale(VoiceLanguage.english, <String>['fr_FR']), isNull);
      expect(PlatformSpeechRecognizer.pickLocale(VoiceLanguage.hausa, <String>['ha_NG', 'en_US']), 'ha_NG');
      expect(PlatformSpeechRecognizer.pickLocale(VoiceLanguage.hausa, <String>['en_US']), isNull);
    });
  });
}

class _Throwing extends FakeSpeechEngine {
  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
    required bool intentLookup,
  }) async =>
      throw StateError('plugin missing');
}
