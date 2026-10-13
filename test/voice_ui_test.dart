import 'package:almus_ai/app.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/voice_settings.dart';
import 'package:almus_ai/voice/voice_settings_store.dart';
import 'package:almus_ai/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fakes.dart';

class _Env {
  _Env({VoiceSettings settings = const VoiceSettings()})
      : store = MemoryVoiceSettingsStore(settings);

  final FakeRecognizer rec = FakeRecognizer();
  final FakeSynthesizer syn = FakeSynthesizer();
  final MemoryVoiceSettingsStore store;
}

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _boot(
  WidgetTester tester,
  _Env env, {
  ChatService? service,
}) async {
  _usePhoneScreen(tester);
  await tester.pumpWidget(
    AlmusApp(
      showSplash: false,
      chatService: service ?? DemoChatService(thinkingDelay: Duration.zero),
      settingsStore: MemorySettingsStore(),
      speechRecognizer: env.rec,
      speechSynthesizer: env.syn,
      voiceSettingsStore: env.store,
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat_input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('send_button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await _settle(tester);
}

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('chat_input'))).controller!.text;

/// Disposes the app so no timers or tickers outlive the test.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('without voice engines the app behaves like Phase 5',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(
      AlmusApp(
        showSplash: false,
        chatService: DemoChatService(thinkingDelay: Duration.zero),
        settingsStore: MemorySettingsStore(),
      ),
    );
    await tester.pump();
    await _openTab(tester, Icons.chat_bubble_outline);
    expect(find.byKey(const Key('mic_button')), findsNothing);
    expect(find.byKey(const Key('auto_speak_toggle')), findsNothing);

    await _openTab(tester, Icons.settings_outlined);
    expect(find.byKey(const Key('auto_speak_switch')), findsNothing);
    await _teardown(tester);
  });

  testWidgets('microphone: listening bar, live text, Done keeps the text',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    // Nothing is requested until the user taps the microphone.
    expect(env.rec.prepareCalls, 0);
    expect(find.byKey(const Key('listening_bar')), findsNothing);

    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    expect(env.rec.prepareCalls, 1);
    expect(find.byKey(const Key('listening_bar')), findsOneWidget);
    expect(find.text('Listening (English)…'), findsOneWidget);
    expect(find.text('LISTENING'), findsOneWidget);

    env.rec.say('hello almus');
    await _settle(tester);
    expect(_inputText(tester), 'hello almus');
    expect(find.text('hello almus'), findsWidgets);

    await tester.tap(find.byKey(const Key('finish_listening_button')));
    await _settle(tester);
    expect(find.byKey(const Key('listening_bar')), findsNothing);
    expect(_inputText(tester), 'hello almus');
    expect(find.byType(MessageBubble), findsNothing,
        reason: 'text is checked by the user, not sent automatically');
    expect(find.text('IDLE'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('cancel discards the recognized text', (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.enterText(find.byKey(const Key('chat_input')), 'abc');
    await tester.pump();
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    env.rec.say('xyz');
    await _settle(tester);
    expect(_inputText(tester), 'abc xyz');

    await tester.tap(find.byKey(const Key('cancel_listening_button')));
    await _settle(tester);
    expect(find.byKey(const Key('listening_bar')), findsNothing);
    expect(_inputText(tester), 'abc');
    expect(env.rec.listening, isFalse);
    expect(find.byType(MessageBubble), findsNothing);
    await _teardown(tester);
  });

  testWidgets('the mic button itself stops listening', (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    env.rec.say('one two');
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    expect(env.rec.stopCalls, 1);
    expect(_inputText(tester), 'one two');
    await _teardown(tester);
  });

  testWidgets('auto-send option sends the recognized text',
      (WidgetTester tester) async {
    final _Env env = _Env(settings: const VoiceSettings(autoSendVoice: true));
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    env.rec.say('hello');
    await _settle(tester);
    env.rec.finish();
    await tester.pump(const Duration(milliseconds: 50));
    await _settle(tester);

    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.text('hello'),
      ),
      findsOneWidget,
    );
    expect(_inputText(tester), '');
    env.syn.startEvent();
    env.syn.completeEvent();
    await _teardown(tester);
  });

  testWidgets('permission denied shows a clear notice', (WidgetTester tester) async {
    final _Env env = _Env();
    env.rec.initResult =
        const RecognizerInit.failed(RecognizerProblem.permissionDenied);
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    expect(find.byKey(const Key('listening_bar')), findsNothing);
    expect(find.byKey(const Key('voice_notice')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('voice_notice'))).data,
      contains('Microphone permission'),
    );
    expect(env.rec.startCalls, 0);

    await tester.tap(find.byKey(const Key('voice_notice_dismiss')));
    await _settle(tester);
    expect(find.byKey(const Key('voice_notice')), findsNothing);
    await _teardown(tester);
  });

  testWidgets('recognition unavailable shows a notice and typing still works',
      (WidgetTester tester) async {
    final _Env env = _Env();
    env.rec.initResult =
        const RecognizerInit.failed(RecognizerProblem.unavailable);
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    expect(find.byKey(const Key('voice_notice')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat_input')), 'typed');
    expect(_inputText(tester), 'typed');
    await _teardown(tester);
  });

  testWidgets('the microphone is disabled while Almus is thinking',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(
      tester,
      env,
      service: DemoChatService(thinkingDelay: const Duration(seconds: 1)),
    );
    await _openTab(tester, Icons.chat_bubble_outline);
    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pump();

    expect(find.text('THINKING'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('mic_button'))).onPressed,
      isNull,
    );
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    env.syn.startEvent();
    env.syn.completeEvent();
    await _teardown(tester);
  });

  testWidgets('replies are read aloud, TALKING follows playback, errors are not read',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    await _send(tester, 'hello');
    expect(env.syn.spoken, hasLength(1));
    expect(env.syn.spoken.single, startsWith('Hello! I am Almus'));
    expect(find.byKey(const Key('speaking_bar')), findsOneWidget);

    env.syn.startEvent();
    await _settle(tester);
    expect(find.text('TALKING'), findsOneWidget);

    await tester.tap(find.byKey(const Key('speech_stop_button')));
    await _settle(tester);
    expect(find.byKey(const Key('speaking_bar')), findsNothing);
    expect(env.syn.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('IDLE'), findsOneWidget);

    await _send(tester, '/error');
    expect(find.text('ALMUS · ERROR'), findsOneWidget);
    expect(env.syn.spoken, hasLength(1), reason: 'errors are never read aloud');
    await _teardown(tester);
  });

  testWidgets('pause and resume buttons appear when the engine can pause',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await _send(tester, 'hello');
    env.syn.startEvent();
    await _settle(tester);

    await tester.tap(find.byKey(const Key('speech_pause_button')));
    await _settle(tester);
    expect(find.text('Paused'), findsOneWidget);
    expect(env.syn.pauseCalls, 1);

    await tester.tap(find.byKey(const Key('speech_resume_button')));
    await _settle(tester);
    expect(env.syn.resumed, hasLength(1));
    env.syn.startEvent();
    env.syn.completeEvent();
    await _teardown(tester);
  });

  testWidgets('no pause button when the engine cannot pause',
      (WidgetTester tester) async {
    final _Env env = _Env();
    env.syn.pauseSupported = false;
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await _send(tester, 'hello');
    env.syn.startEvent();
    await _settle(tester);
    expect(find.byKey(const Key('speech_pause_button')), findsNothing);
    expect(find.byKey(const Key('speech_stop_button')), findsOneWidget);
    env.syn.completeEvent();
    await _teardown(tester);
  });

  testWidgets('header toggle turns automatic speech off; speaker button still works',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.tap(find.byKey(const Key('auto_speak_toggle')));
    await _settle(tester);
    expect(env.store.settings.autoSpeak, isFalse);

    await _send(tester, 'hello');
    expect(env.syn.spoken, isEmpty);

    final Finder speaker = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byIcon(Icons.volume_up_outlined),
    );
    expect(speaker, findsOneWidget);
    await tester.tap(speaker);
    await _settle(tester);
    expect(env.syn.spoken, hasLength(1));
    env.syn.startEvent();
    await _settle(tester);

    // While playing, the same button stops the reading.
    await tester.tap(find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byIcon(Icons.stop_circle_outlined),
    ));
    await _settle(tester);
    expect(find.byKey(const Key('speaking_bar')), findsNothing);
    await _teardown(tester);
  });

  testWidgets('user messages and error messages have no speaker button',
      (WidgetTester tester) async {
    final _Env env = _Env(settings: const VoiceSettings(autoSpeak: false));
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await _send(tester, '/error');
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byIcon(Icons.volume_up_outlined),
      ),
      findsNothing,
    );
    await _teardown(tester);
  });

  testWidgets('leaving the chat tab closes the microphone',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.chat_bubble_outline);
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    expect(env.rec.listening, isTrue);

    await _openTab(tester, Icons.home_outlined);
    await _settle(tester);
    expect(env.rec.listening, isFalse);
    expect(env.rec.cancelCalls, greaterThanOrEqualTo(1));
    await _teardown(tester);
  });

  testWidgets('settings: voice options are saved and Hausa is selectable',
      (WidgetTester tester) async {
    final _Env env = _Env();
    await _boot(tester, env);
    await _openTab(tester, Icons.settings_outlined);

    expect(find.byKey(const Key('auto_speak_switch')), findsOneWidget);

    await tester.tap(find.byKey(const Key('auto_send_switch')));
    await _settle(tester);
    expect(env.store.settings.autoSendVoice, isTrue);

    await tester.tap(find.byKey(const Key('auto_speak_switch')));
    await _settle(tester);
    expect(env.store.settings.autoSpeak, isFalse);

    await tester.tap(find.descendant(
      of: find.byKey(const Key('voice_language_selector')),
      matching: find.text('Hausa'),
    ));
    await _settle(tester);
    expect(env.store.settings.language, VoiceLanguage.hausa);

    await tester.tap(find.byKey(const Key('test_voice_button')));
    await _settle(tester);
    expect(env.syn.lastLanguage, VoiceLanguage.hausa);
    expect(env.syn.spoken, hasLength(1));
    env.syn.startEvent();
    env.syn.completeEvent();
    await _teardown(tester);
  });
}
