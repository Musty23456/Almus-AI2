import 'dart:async';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/voice_controller.dart';
import 'package:almus_ai/voice/voice_settings.dart';
import 'package:almus_ai/voice/voice_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fakes.dart';

class Rig {
  Rig({VoiceSettings settings = const VoiceSettings()}) {
    voiceSettings = VoiceSettingsController(MemoryVoiceSettingsStore(settings))..value = settings;
    chat = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
      happyHold: const Duration(milliseconds: 20),
    );
    voice = VoiceController(
      recognizer: rec,
      synthesizer: syn,
      settings: voiceSettings,
      avatar: chat,
    );
    voice.onTranscript = (String t, bool f) => transcripts.add((t, f));
  }

  final FakeRecognizer rec = FakeRecognizer();
  final FakeSynthesizer syn = FakeSynthesizer();
  late final VoiceSettingsController voiceSettings;
  late final ChatController chat;
  late final VoiceController voice;
  final List<(String, bool)> transcripts = <(String, bool)>[];

  void dispose() {
    voice.dispose();
    chat.dispose();
    voiceSettings.dispose();
  }
}

void main() {
  test('permission denied: a clear notice, nothing is started', () async {
    final Rig r = Rig();
    r.rec.initResult = const RecognizerInit.failed(RecognizerProblem.permissionDenied);
    await r.voice.startListening();
    expect(r.voice.notice, isNotNull);
    expect(r.voice.noticeIsError, isTrue);
    expect(r.voice.notice!.toLowerCase(), contains('microphone'));
    expect(r.rec.startCalls, 0);
    expect(r.voice.micActive, isFalse);
    r.dispose();
  });

  test('speech engine unavailable: guidance mentions what to install or enable', () async {
    final Rig r = Rig();
    r.rec.initResult = const RecognizerInit.failed(RecognizerProblem.unavailable);
    await r.voice.startListening();
    expect(r.voice.notice, isNotNull);
    expect(r.voice.micActive, isFalse);
    r.dispose();
  });

  test('Hausa unsupported by the engine: honest notice, no recording', () async {
    final Rig r = Rig(settings: const VoiceSettings(language: VoiceLanguage.hausa));
    r.rec.initResult = const RecognizerInit.failed(RecognizerProblem.languageUnsupported);
    await r.voice.startListening();
    expect(r.voice.notice, isNotNull);
    expect(r.rec.startCalls, 0);
    r.dispose();
  });

  test('the engine never starting listening shows the not-started guidance', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.rec.fail(RecognizerProblem.notStarted);
    expect(r.voice.notice, contains('speech service'));
    expect(r.voice.micActive, isFalse);
    r.dispose();
  });

  test('empty recognition result: a notice, no transcript, no preview', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.rec.finish();
    expect(r.transcripts, isEmpty);
    expect(r.voice.heardPreview, isNull);
    expect(r.voice.notice, isNotNull);
    expect(r.voice.micActive, isFalse);
    r.dispose();
  });

  test('recognized words become a preview until sent, discarded or retried', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.rec.say('sannu', isFinal: false);
    r.rec.say('sannu Almus', isFinal: true);
    r.rec.finish();
    expect(r.voice.heardPreview, 'sannu Almus');
    expect(r.transcripts.last, ('sannu Almus', true));
    r.voice.clearHeardPreview();
    expect(r.voice.heardPreview, isNull);
    r.dispose();
  });

  test('the bar says "starting" until the engine really listens (micOpen)', () async {
    final Rig r = Rig();
    r.rec.autoListening = false;
    await r.voice.startListening();
    expect(r.voice.micActive, isTrue);
    expect(r.voice.micOpen, isFalse);
    r.rec.engineListening();
    expect(r.voice.micOpen, isTrue);
    r.rec.finish();
    expect(r.voice.micOpen, isFalse);
    r.dispose();
  });

  test('stop shows "processing" until the engine delivers, then clears', () async {
    final Rig r = Rig();
    r.rec.finishOnStop = false;
    await r.voice.startListening();
    r.rec.say('abc');
    unawaited(r.voice.stopListening());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(r.voice.isProcessing, isTrue);
    r.rec.say('abc def', isFinal: true);
    r.rec.finish();
    expect(r.voice.isProcessing, isFalse);
    expect(r.voice.heardPreview, 'abc def');
    r.dispose();
  });

  test('interrupted session (engine error mid-way) ends cleanly and can start again', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.rec.say('half a sentence');
    r.rec.fail(RecognizerProblem.other);
    expect(r.voice.micActive, isFalse);
    await r.voice.startListening();
    expect(r.rec.startCalls, 2);
    expect(r.voice.micActive, isTrue);
    r.dispose();
  });

  test('five voice sessions in a row, each with its own text', () async {
    final Rig r = Rig();
    for (int i = 0; i < 5; i++) {
      await r.voice.startListening();
      expect(r.voice.heardPreview, isNull, reason: 'cleared at start of session $i');
      r.rec.say('turn $i', isFinal: true);
      r.rec.finish();
      expect(r.voice.heardPreview, 'turn $i');
    }
    expect(r.rec.startCalls, 5);
    r.dispose();
  });

  test('retry cancels the old session and starts a new one', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.rec.say('wrong words');
    await r.voice.retryListening();
    expect(r.rec.cancelCalls, greaterThan(0));
    expect(r.rec.startCalls, 2);
    expect(r.voice.transcript, isEmpty);
    r.dispose();
  });

  test('a late callback from a cancelled session cannot revive it', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.voice.cancelListening(quiet: true);
    r.rec.say('ghost', isFinal: true);
    r.rec.finish();
    expect(r.transcripts, isEmpty);
    expect(r.voice.heardPreview, isNull);
    r.dispose();
  });

  test('leaving the screen while listening closes the microphone', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.voice.cancelListening(quiet: true);
    expect(r.voice.micActive, isFalse);
    expect(r.rec.cancelCalls, greaterThan(0));
    r.dispose();
    expect(r.rec.disposed, isTrue);
  });

  test('app going to the background interrupts listening', () async {
    final Rig r = Rig();
    await r.voice.startListening();
    r.voice.interrupt();
    expect(r.voice.micActive, isFalse);
    r.dispose();
  });
}
