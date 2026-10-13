import 'package:almus_ai/voice/voice_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const VoiceStateMachine m = VoiceStateMachine();

  VoicePhase go(VoicePhase from, VoiceEvent e) {
    final VoiceTransition t = m.apply(from, e);
    expect(t.accepted, isTrue, reason: '$e should be accepted in $from');
    return t.phase;
  }

  void ignored(VoicePhase from, VoiceEvent e) {
    final VoiceTransition t = m.apply(from, e);
    expect(t.accepted, isFalse, reason: '$e should be ignored in $from');
    expect(t.phase, from);
  }

  group('listening flow', () {
    test('mic -> preparing -> listening -> idle', () {
      VoicePhase p = VoicePhase.idle;
      p = go(p, VoiceEvent.micPressed);
      expect(p, VoicePhase.preparing);
      p = go(p, VoiceEvent.recognizerReady);
      expect(p, VoicePhase.listening);
      p = go(p, VoiceEvent.recognitionFinished);
      expect(p, VoicePhase.idle);
    });

    test('permission denied or unavailable returns to idle', () {
      expect(
        go(VoicePhase.preparing, VoiceEvent.recognizerFailed),
        VoicePhase.idle,
      );
    });

    test('cancel works while preparing and while listening', () {
      expect(go(VoicePhase.preparing, VoiceEvent.listenCancelled), VoicePhase.idle);
      expect(go(VoicePhase.listening, VoiceEvent.listenCancelled), VoicePhase.idle);
    });

    test('recognition error ends listening', () {
      expect(go(VoicePhase.listening, VoiceEvent.listenError), VoicePhase.idle);
    });

    test('pressing the mic twice does not start a second session', () {
      ignored(VoicePhase.preparing, VoiceEvent.micPressed);
      ignored(VoicePhase.listening, VoiceEvent.micPressed);
    });
  });

  group('speaking flow', () {
    test('speak -> started -> completed -> idle', () {
      VoicePhase p = go(VoicePhase.idle, VoiceEvent.speakRequested);
      expect(p, VoicePhase.speaking);
      p = go(p, VoiceEvent.speechStarted);
      expect(p, VoicePhase.speaking);
      p = go(p, VoiceEvent.speechCompleted);
      expect(p, VoicePhase.idle);
    });

    test('stop and error both return to idle from speaking and paused', () {
      for (final VoicePhase from in <VoicePhase>[
        VoicePhase.speaking,
        VoicePhase.paused,
      ]) {
        expect(go(from, VoiceEvent.speechStopped), VoicePhase.idle);
        expect(go(from, VoiceEvent.speechError), VoicePhase.idle);
        expect(go(from, VoiceEvent.speechCompleted), VoicePhase.idle);
      }
    });

    test('pause and resume', () {
      VoicePhase p = go(VoicePhase.speaking, VoiceEvent.pauseRequested);
      expect(p, VoicePhase.paused);
      p = go(p, VoiceEvent.resumeRequested);
      expect(p, VoicePhase.speaking);
    });

    test('pause only applies while speaking, resume only while paused', () {
      ignored(VoicePhase.idle, VoiceEvent.pauseRequested);
      ignored(VoicePhase.paused, VoiceEvent.pauseRequested);
      ignored(VoicePhase.idle, VoiceEvent.resumeRequested);
      ignored(VoicePhase.speaking, VoiceEvent.resumeRequested);
    });

    test('a new reply can replace playback, also while paused', () {
      expect(go(VoicePhase.speaking, VoiceEvent.speakRequested), VoicePhase.speaking);
      expect(go(VoicePhase.paused, VoiceEvent.speakRequested), VoicePhase.speaking);
    });
  });

  group('microphone and speaker never overlap', () {
    test('speech cannot start while the microphone is requested or open', () {
      ignored(VoicePhase.preparing, VoiceEvent.speakRequested);
      ignored(VoicePhase.listening, VoiceEvent.speakRequested);
    });

    test('pressing the mic while speaking or paused interrupts playback', () {
      expect(go(VoicePhase.speaking, VoiceEvent.micPressed), VoicePhase.preparing);
      expect(go(VoicePhase.paused, VoiceEvent.micPressed), VoicePhase.preparing);
    });
  });

  group('interruptions', () {
    test('any active phase falls back to idle', () {
      for (final VoicePhase from in <VoicePhase>[
        VoicePhase.preparing,
        VoicePhase.listening,
        VoicePhase.speaking,
        VoicePhase.paused,
      ]) {
        expect(go(from, VoiceEvent.interrupted), VoicePhase.idle);
      }
    });

    test('interrupting idle does nothing', () {
      ignored(VoicePhase.idle, VoiceEvent.interrupted);
    });
  });

  group('stale events are ignored, never fatal', () {
    test('late engine events while idle', () {
      for (final VoiceEvent e in <VoiceEvent>[
        VoiceEvent.recognizerReady,
        VoiceEvent.recognizerFailed,
        VoiceEvent.recognitionFinished,
        VoiceEvent.listenCancelled,
        VoiceEvent.listenError,
        VoiceEvent.speechStarted,
        VoiceEvent.speechCompleted,
        VoiceEvent.speechStopped,
        VoiceEvent.speechError,
      ]) {
        ignored(VoicePhase.idle, e);
      }
    });

    test('speech events while listening do not change the phase', () {
      for (final VoiceEvent e in <VoiceEvent>[
        VoiceEvent.speechStarted,
        VoiceEvent.speechCompleted,
        VoiceEvent.speechStopped,
        VoiceEvent.speechError,
      ]) {
        ignored(VoicePhase.listening, e);
      }
    });

    test('recognizer events while speaking do not change the phase', () {
      for (final VoiceEvent e in <VoiceEvent>[
        VoiceEvent.recognizerReady,
        VoiceEvent.recognizerFailed,
        VoiceEvent.recognitionFinished,
        VoiceEvent.listenCancelled,
        VoiceEvent.listenError,
      ]) {
        ignored(VoicePhase.speaking, e);
      }
    });
  });

  test('every (phase, event) pair yields a defined phase', () {
    for (final VoicePhase p in VoicePhase.values) {
      for (final VoiceEvent e in VoiceEvent.values) {
        final VoiceTransition t = m.apply(p, e);
        expect(VoicePhase.values, contains(t.phase));
        if (!t.accepted) expect(t.phase, p);
      }
    }
  });

  test('no event sequence can leave the machine stuck', () {
    // From every phase, an interruption (or the matching end event) always
    // gets back to idle within one step.
    for (final VoicePhase p in VoicePhase.values) {
      final VoicePhase next = m.apply(p, VoiceEvent.interrupted).phase;
      expect(next, VoicePhase.idle);
    }
  });
}
