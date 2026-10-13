import 'dart:async';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/speech_synthesizer.dart';
import 'package:almus_ai/voice/voice_controller.dart';
import 'package:almus_ai/voice/voice_settings.dart';
import 'package:almus_ai/voice/voice_settings_store.dart';
import 'package:almus_ai/voice/voice_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fakes.dart';

/// Chat engine whose reply is released by the test.
class _ManualService implements ChatService {
  final Completer<String> completer = Completer<String>();
  @override
  String get engineName => 'TEST';
  @override
  bool get isDemo => true;
  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) =>
      completer.future;
}

ChatMessage _reply(
  String text, {
  String id = 'm1',
  bool isError = false,
  MessageSender sender = MessageSender.assistant,
}) =>
    ChatMessage(
      id: id,
      text: text,
      sender: sender,
      timestamp: DateTime(2026, 1, 1),
      conversationId: 'c1',
      isError: isError,
    );

/// A voice controller wired to fakes and a real ChatController (the avatar).
class _Rig {
  _Rig({
    VoiceSettings settings = const VoiceSettings(),
    ChatService? service,
    Duration speechStartTimeout = const Duration(seconds: 8),
    Duration stopTimeout = const Duration(seconds: 3),
  }) {
    voiceSettings = VoiceSettingsController(MemoryVoiceSettingsStore(settings))
      ..value = settings;
    chat = ChatController(
      service: service ?? DemoChatService(thinkingDelay: Duration.zero),
      happyHold: const Duration(milliseconds: 20),
      onAssistantReply: (ChatMessage m) => voice.handleReply(m),
      onConversationChanged: () => voice.stopAll(),
    );
    voice = VoiceController(
      recognizer: rec,
      synthesizer: syn,
      settings: voiceSettings,
      avatar: chat,
      speechStartTimeout: speechStartTimeout,
      stopTimeout: stopTimeout,
    );
    voice.onTranscript = (String t, bool f) => transcripts.add((t, f));
    voice.onCancelled = () => cancelled++;
  }

  final FakeRecognizer rec = FakeRecognizer();
  final FakeSynthesizer syn = FakeSynthesizer();
  late final VoiceSettingsController voiceSettings;
  late final ChatController chat;
  late final VoiceController voice;
  final List<(String, bool)> transcripts = <(String, bool)>[];
  int cancelled = 0;

  RobotState get avatar => chat.robotState.value;

  void dispose() {
    voice.dispose();
    chat.dispose();
    voiceSettings.dispose();
  }
}

Future<void> _wait([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('voice input', () {
    test('no permission request or listening before the user taps the mic',
        () {
      final _Rig r = _Rig();
      expect(r.rec.prepareCalls, 0);
      expect(r.rec.startCalls, 0);
      expect(r.voice.phase, VoicePhase.idle);
      r.dispose();
    });

    test('tap -> LISTENING avatar -> final text -> IDLE', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      expect(r.voice.phase, VoicePhase.listening);
      expect(r.rec.prepareCalls, 1);
      expect(r.avatar, RobotState.listening);
      expect(r.voice.micActive, isTrue);

      r.rec.say('hello');
      r.rec.say('hello almus');
      expect(r.voice.transcript, 'hello almus');
      expect(r.transcripts.last, ('hello almus', false));

      r.rec.finish();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.transcripts.last, ('hello almus', true));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('uses the selected language and the locale the engine reported',
        () async {
      final _Rig r = _Rig(
        settings: const VoiceSettings(language: VoiceLanguage.hausa),
      );
      r.rec.initResult = const RecognizerInit.ready('ha_NG');
      await r.voice.startListening();
      expect(r.rec.lastLanguage, VoiceLanguage.hausa);
      expect(r.rec.lastLocale, 'ha_NG');
      r.voice.cancelListening();
      r.dispose();
    });

    test('cancel discards the text and tells the screen', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.rec.say('secret words');
      r.voice.cancelListening();

      expect(r.voice.phase, VoicePhase.idle);
      expect(r.cancelled, 1);
      expect(r.rec.cancelCalls, 1);
      expect(r.transcripts.where((t) => t.$2), isEmpty,
          reason: 'no final text after cancel');
      expect(r.voice.transcript, '');
      expect(r.avatar, RobotState.idle);

      // Late engine events from the cancelled session are ignored.
      r.rec.finish();
      expect(r.transcripts.where((t) => t.$2), isEmpty);
      r.dispose();
    });

    test('quiet cancel does not notify the screen', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.voice.cancelListening(quiet: true);
      expect(r.cancelled, 0);
      r.dispose();
    });

    test('done keeps what was heard', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.rec.say('keep this');
      await r.voice.stopListening();
      expect(r.rec.stopCalls, 1);
      expect(r.transcripts.last, ('keep this', true));
      expect(r.voice.phase, VoicePhase.idle);
      r.dispose();
    });

    test('done still ends if the engine never reports back', () async {
      final _Rig r = _Rig(stopTimeout: const Duration(milliseconds: 20));
      r.rec.finishOnStop = false;
      await r.voice.startListening();
      r.rec.say('late');
      await r.voice.stopListening();
      expect(r.voice.phase, VoicePhase.listening);
      await _wait();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.transcripts.last, ('late', true));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('permission denied: clear notice, no listening, no error avatar',
        () async {
      final _Rig r = _Rig();
      r.rec.initResult =
          const RecognizerInit.failed(RecognizerProblem.permissionDenied);
      await r.voice.startListening();

      expect(r.voice.phase, VoicePhase.idle);
      expect(r.rec.startCalls, 0);
      expect(r.voice.notice, contains('Microphone permission'));
      expect(r.voice.notice, contains('type'));
      expect(r.voice.noticeIsError, isTrue);
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('recognition unavailable: says so and offers typing', () async {
      final _Rig r = _Rig();
      r.rec.initResult =
          const RecognizerInit.failed(RecognizerProblem.unavailable);
      await r.voice.startListening();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.notice, contains('not available'));
      expect(r.voice.notice, contains('type'));
      r.dispose();
    });

    test('Hausa unsupported: honest message, never silently English',
        () async {
      final _Rig r = _Rig(
        settings: const VoiceSettings(language: VoiceLanguage.hausa),
      );
      r.rec.initResult =
          const RecognizerInit.failed(RecognizerProblem.languageUnsupported);
      await r.voice.startListening();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.rec.startCalls, 0);
      expect(r.voice.notice, contains('Hausa'));
      expect(r.voice.notice, contains('English'));
      r.dispose();
    });

    test('nothing heard: friendly notice, back to IDLE', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.rec.fail(RecognizerProblem.noSpeech);
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.notice, contains('did not hear'));
      expect(r.voice.noticeIsError, isFalse);
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('a timeout after partial text still delivers that text', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.rec.say('half a sentence');
      r.rec.fail(RecognizerProblem.noSpeech);
      expect(r.transcripts.last, ('half a sentence', true));
      r.dispose();
    });

    test('engine failure shows ERROR on the avatar, then IDLE', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.rec.fail(RecognizerProblem.other);
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.avatar, RobotState.error);
      expect(r.voice.notice, isNotNull);
      r.dispose();
    });

    test('microphone is refused while the AI is thinking', () async {
      final _ManualService service = _ManualService();
      final _Rig r = _Rig(service: service);
      unawaited(r.chat.send('hi'));
      await _wait(10);
      expect(r.avatar, RobotState.thinking);

      await r.voice.startListening();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.rec.prepareCalls, 0);
      expect(r.voice.notice, contains('still answering'));
      expect(r.avatar, RobotState.thinking);

      service.completer.complete('done');
      await _wait(10);
      r.dispose();
    });

    test('cancel while the permission dialog is open stays cancelled',
        () async {
      final _Rig r = _Rig();
      r.rec.prepareGate = Completer<RecognizerInit>();
      final Future<void> start = r.voice.startListening();
      await _wait(5);
      expect(r.voice.phase, VoicePhase.preparing);
      expect(r.voice.isPreparing, isTrue);

      r.voice.cancelListening();
      expect(r.voice.phase, VoicePhase.idle);

      r.rec.prepareGate!.complete(const RecognizerInit.ready('en_US'));
      await start;
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.rec.startCalls, 0, reason: 'must not open the mic after cancel');
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('app going to the background keeps a pending permission request '
        'but closes an open microphone', () async {
      final _Rig r = _Rig();
      r.rec.prepareGate = Completer<RecognizerInit>();
      final Future<void> start = r.voice.startListening();
      await _wait(5);
      r.voice.interrupt(); // permission dialog makes the app inactive
      expect(r.voice.phase, VoicePhase.preparing);

      r.rec.prepareGate!.complete(const RecognizerInit.ready('en_US'));
      await start;
      expect(r.voice.phase, VoicePhase.listening);

      r.voice.interrupt(); // real background
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.rec.cancelCalls, greaterThan(0));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('a new conversation closes the microphone', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.chat.newConversation();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });
  });

  group('voice output', () {
    test('automatic speech reads the cleaned reply', () async {
      final _Rig r = _Rig();
      r.voice.handleReply(_reply('Hello **world**, see https://example.com'));
      await _wait(5);
      expect(r.syn.spoken, <String>['Hello world, see']);
      expect(r.voice.phase, VoicePhase.speaking);
      expect(r.voice.speakingMessageId, 'm1');
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('passes the configured rate and volume to the engine', () async {
      final _Rig r = _Rig(
        settings: const VoiceSettings(speechRate: 0.8, volume: 0.4),
      );
      await r.voice.speakText('Hi there');
      expect(r.syn.rate, 0.8);
      expect(r.syn.volume, 0.4);
      expect(r.syn.lastLanguage, VoiceLanguage.english);
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('automatic speech can be disabled', () async {
      final _Rig r = _Rig(settings: const VoiceSettings(autoSpeak: false));
      r.voice.handleReply(_reply('Hello'));
      await _wait(5);
      expect(r.syn.spoken, isEmpty);
      expect(r.syn.prepareCalls, 0);
      expect(r.voice.phase, VoicePhase.idle);

      // The manual speaker button still works.
      await r.voice.speakMessage(_reply('Hello'));
      expect(r.syn.spoken, <String>['Hello']);
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('error messages and user messages are never read aloud', () async {
      final _Rig r = _Rig();
      r.voice.handleReply(_reply('Network failed', isError: true));
      r.voice.handleReply(_reply('typed by me', sender: MessageSender.user));
      await r.voice.speakMessage(_reply('Network failed', isError: true));
      await _wait(5);
      expect(r.syn.spoken, isEmpty);
      expect(r.voice.phase, VoicePhase.idle);
      r.dispose();
    });

    test('code blocks and symbols are not read; nothing to read is reported',
        () async {
      final _Rig r = _Rig();
      await r.voice.speakText('```dart\nprint(1);\n```');
      expect(r.syn.spoken, isEmpty);
      expect(r.voice.notice, contains('nothing to read'));
      r.dispose();
    });

    test('TALKING starts when audio starts and IDLE returns after it ends',
        () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Hello there');
      expect(r.voice.phase, VoicePhase.speaking);
      expect(r.avatar, RobotState.idle, reason: 'audio has not started yet');

      r.syn.startEvent();
      expect(r.avatar, RobotState.talking);

      await _wait(100);
      expect(r.avatar, RobotState.talking, reason: 'holds for the whole audio');

      r.syn.completeEvent();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.avatar, RobotState.happy, reason: 'brief smile after natural end');
      await _wait(80);
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('stop goes straight to IDLE and stops the engine', () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Hello there');
      r.syn.startEvent();
      await r.voice.stopSpeaking();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.avatar, RobotState.idle);
      expect(r.syn.stopCalls, 1);
      r.dispose();
    });

    test('whole flow for a chat reply: THINKING -> TALKING -> IDLE', () async {
      final _ManualService service = _ManualService();
      final _Rig r = _Rig(service: service);
      r.syn.autoStart = true;

      unawaited(r.chat.send('hi'));
      await _wait(10);
      expect(r.avatar, RobotState.thinking);

      service.completer.complete('Good morning, Almus here.');
      await _wait(20);
      expect(r.syn.spoken, <String>['Good morning, Almus here.']);
      expect(r.avatar, RobotState.talking);

      r.syn.completeEvent();
      await _wait(80);
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('pause and resume when supported', () async {
      final _Rig r = _Rig();
      await r.voice.speakText('A longer sentence to read.');
      r.syn.startEvent();
      expect(r.avatar, RobotState.talking);

      await r.voice.pauseSpeaking();
      expect(r.voice.phase, VoicePhase.paused);
      expect(r.voice.isPaused, isTrue);
      expect(r.avatar, RobotState.idle, reason: 'no talking while paused');

      await r.voice.resumeSpeaking();
      expect(r.voice.phase, VoicePhase.speaking);
      expect(r.syn.resumed, <String>['A longer sentence to read.']);
      r.syn.startEvent();
      expect(r.avatar, RobotState.talking);

      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('a cancel event caused by pausing is not treated as a stop',
        () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Pause me');
      r.syn.startEvent();
      await r.voice.pauseSpeaking();
      r.syn.cancelEvent(); // some engines report pause this way
      expect(r.voice.phase, VoicePhase.paused);
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('pause is not offered when the engine cannot pause', () async {
      final _Rig r = _Rig();
      r.syn.pauseSupported = false;
      expect(r.voice.canPause, isFalse);
      await r.voice.speakText('Hello');
      r.syn.startEvent();
      await r.voice.pauseSpeaking();
      expect(r.voice.phase, VoicePhase.speaking);
      expect(r.voice.notice, contains('cannot pause'));
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('failed pause falls back to stopping, with an explanation', () async {
      final _Rig r = _Rig();
      r.syn.pauseResult = false;
      await r.voice.speakText('Hello');
      r.syn.startEvent();
      await r.voice.pauseSpeaking();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.notice, contains('not supported'));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('no text-to-speech engine: notice once, replies stay silent',
        () async {
      final _Rig r = _Rig();
      r.syn.status = SynthesizerStatus.unavailable;
      r.voice.handleReply(_reply('Hello'));
      await _wait(10);
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.speechAvailable, isFalse);
      expect(r.voice.notice, contains('not available'));
      expect(r.voice.noticeIsError, isTrue);

      // Later replies do not even try again.
      r.voice.handleReply(_reply('Again', id: 'm2'));
      await _wait(5);
      expect(r.syn.prepareCalls, 1);
      expect(r.syn.spoken, isEmpty);
      r.dispose();
    });

    test('missing Hausa voice: warns once and still speaks', () async {
      final _Rig r = _Rig(
        settings: const VoiceSettings(language: VoiceLanguage.hausa),
      );
      r.syn.status = SynthesizerStatus.languageMissing;
      await r.voice.speakText('Sannu');
      expect(r.syn.lastLanguage, VoiceLanguage.hausa);
      expect(r.voice.notice, contains('Hausa'));
      expect(r.syn.spoken, <String>['Sannu']);

      r.voice.dismissNotice();
      await r.voice.stopSpeaking();
      await r.voice.speakText('Barka');
      expect(r.voice.notice, isNull, reason: 'only warned once');
      await r.voice.stopSpeaking();
      r.dispose();
    });

    test('speech that never starts times out cleanly', () async {
      final _Rig r = _Rig(
        speechStartTimeout: const Duration(milliseconds: 30),
      );
      await r.voice.speakText('Hello');
      expect(r.voice.phase, VoicePhase.speaking);
      await _wait(80);
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.noticeIsError, isTrue);
      expect(r.voice.notice, contains('did not start'));
      r.dispose();
    });

    test('engine error: friendly notice without technical details', () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Hello');
      r.syn.startEvent();
      r.syn.errorEvent('ERROR_SYNTHESIS code=-8 at com.google.tts.Foo');
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.voice.notice, isNot(contains('com.google')));
      expect(r.voice.notice, isNot(contains('-8')));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });

    test('a late cancel from the replaced reply does not stop the new one',
        () async {
      final _Rig r = _Rig();
      await r.voice.speakText('First reply');
      r.syn.startEvent();
      await r.voice.speakText('Second reply');
      expect(r.syn.stopCalls, 1);
      r.syn.cancelEvent(); // stale event for "First reply"
      expect(r.voice.phase, VoicePhase.speaking);
      r.syn.startEvent();
      r.syn.completeEvent();
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.syn.spoken, <String>['First reply', 'Second reply']);
      r.dispose();
    });

    test('speech engine pausing on its own (audio focus) is mirrored',
        () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Hello');
      r.syn.startEvent();
      r.syn.pauseEvent();
      expect(r.voice.phase, VoicePhase.paused);
      expect(r.avatar, RobotState.idle);
      r.syn.continueEvent();
      expect(r.voice.phase, VoicePhase.speaking);
      expect(r.avatar, RobotState.talking);
      await r.voice.stopSpeaking();
      r.dispose();
    });
  });

  group('microphone and speaker never overlap', () {
    test('tapping the mic stops speech first', () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Talking now');
      r.syn.startEvent();
      expect(r.avatar, RobotState.talking);

      await r.voice.startListening();
      expect(r.syn.stopCalls, greaterThanOrEqualTo(1));
      expect(r.voice.phase, VoicePhase.listening);
      expect(r.avatar, RobotState.listening);
      r.voice.cancelListening();
      r.dispose();
    });

    test('replies are not spoken while the microphone is open', () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.voice.handleReply(_reply('Hello'));
      await r.voice.speakText('Hello');
      expect(r.syn.spoken, isEmpty);
      expect(r.voice.phase, VoicePhase.listening);
      r.voice.cancelListening();
      r.dispose();
    });

    test('a new conversation stops speech', () async {
      final _Rig r = _Rig();
      await r.voice.speakText('Hello');
      r.syn.startEvent();
      r.chat.newConversation();
      await _wait(5);
      expect(r.voice.phase, VoicePhase.idle);
      expect(r.syn.stopCalls, greaterThanOrEqualTo(1));
      expect(r.avatar, RobotState.idle);
      r.dispose();
    });
  });

  group('lifecycle', () {
    test('dispose closes the microphone and the speaker, later events are safe',
        () async {
      final _Rig r = _Rig();
      await r.voice.startListening();
      r.voice.dispose();
      expect(r.rec.cancelCalls, 1);
      expect(r.syn.stopCalls, 1);
      // Events after dispose must not throw.
      r.rec.say('late');
      r.syn.startEvent();
      r.syn.completeEvent();
      r.chat.dispose();
      r.voiceSettings.dispose();
    });
  });
}
