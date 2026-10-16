import 'package:almus_ai/app.dart';
import 'package:almus_ai/attachments/attachment_picker.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:almus_ai/voice/voice_consent.dart';
import 'package:almus_ai/voice/voice_settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_controller_test.dart' show FakePicker, pick;
import 'attachment_fixtures.dart';
import 'voice_fakes.dart';

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

Future<void> _boot(
  WidgetTester tester, {
  FakePicker? picker,
  FakeRecognizer? rec,
  VoiceConsentStore? consent,
}) async {
  _phone(tester);
  await tester.pumpWidget(
    AlmusApp(
      showSplash: false,
      chatService: DemoChatService(thinkingDelay: Duration.zero),
      settingsStore: MemorySettingsStore(),
      attachmentPicker: picker,
      speechRecognizer: rec,
      speechSynthesizer: rec == null ? null : FakeSynthesizer(),
      voiceSettingsStore: rec == null ? null : MemoryVoiceSettingsStore(),
      voiceConsent: consent,
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byIcon(Icons.chat_bubble_outline));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void main() {
  testWidgets('no picker: no attach button', (WidgetTester tester) async {
    await _boot(tester);
    expect(find.byKey(const Key('attach_button')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('attach sheet offers every source; choosing a file shows a preview chip with size and status; remove works',
      (WidgetTester tester) async {
    final FakePicker picker = FakePicker()
      ..next = <PickedAttachment>[pick('notes.txt', utf8Bytes('hello world')), pick('photo.png', pngBytes())];
    await _boot(tester, picker: picker);

    await tester.tap(find.byKey(const Key('attach_button')));
    await tester.pumpAndSettle();
    for (final String k in <String>[
      'attach_image',
      'attach_camera',
      'attach_document',
      'attach_pdf',
      'attach_text',
      'attach_spreadsheet',
    ]) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    await tester.tap(find.byKey(const Key('attach_document')));
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(picker.asked, <AttachmentSource>[AttachmentSource.document]);
    expect(find.byKey(const Key('attachment_strip')), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.textContaining('Text file · 11 B'), findsOneWidget);
    // DEMO MODE cannot read files: the chip says so instead of "ready".
    expect(find.textContaining('Not read by DEMO MODE'), findsOneWidget);
    expect(find.textContaining('Not analyzed by the AI'), findsOneWidget);
    expect(find.byKey(const Key('thumb_att-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove_att-1')));
    await _settle(tester);
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('photo.png'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('validation errors are shown and can be dismissed', (WidgetTester tester) async {
    final FakePicker picker = FakePicker()..next = <PickedAttachment>[pick('tool.exe', utf8Bytes('x'))];
    await _boot(tester, picker: picker);
    await tester.tap(find.byKey(const Key('attach_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach_pdf')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(find.byKey(const Key('attachment_problems')), findsOneWidget);
    expect(find.textContaining('not supported'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attachment_problems_dismiss')));
    await _settle(tester);
    expect(find.byKey(const Key('attachment_problems')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sending in DEMO with a file: the user is warned first; "Send anyway" keeps it marked not analyzed',
      (WidgetTester tester) async {
    final FakePicker picker = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('hello'))];
    await _boot(tester, picker: picker);
    await tester.tap(find.byKey(const Key('attach_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach_text')));
    await tester.pumpAndSettle();
    await _settle(tester);

    await tester.enterText(find.byKey(const Key('chat_input')), 'Please read it');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skipped_files_dialog')), findsOneWidget);
    expect(find.textContaining('DEMO MODE does not read attached files'), findsOneWidget);

    await tester.tap(find.byKey(const Key('skip_send')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(find.byKey(const Key('attachment_strip')), findsNothing, reason: 'files leave the box after sending');
    expect(find.textContaining('a.txt · 5 B · not analyzed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('"Remove them" drops unreadable files and does not send an empty message', (WidgetTester tester) async {
    final FakePicker picker = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('hello'))];
    await _boot(tester, picker: picker);
    await tester.tap(find.byKey(const Key('attach_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach_text')));
    await tester.pumpAndSettle();
    await _settle(tester);

    // File only, no words, and DEMO cannot read it: a hint, no dialog, nothing sent.
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skipped_files_dialog')), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byKey(const Key('attachment_strip')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hi');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skip_remove')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(find.byKey(const Key('attachment_strip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first microphone use asks for consent; declining starts nothing; accepting starts once and is remembered',
      (WidgetTester tester) async {
    final FakeRecognizer rec = FakeRecognizer();
    final MemoryVoiceConsentStore consent = MemoryVoiceConsentStore();
    await _boot(tester, rec: rec, consent: consent);

    await tester.tap(find.byKey(const Key('mic_button')));
    await tester.pumpAndSettle();
    expect(find.text('Before you use the microphone'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice_consent_no')));
    await tester.pumpAndSettle();
    expect(rec.prepareCalls, 0);
    expect(consent.granted, isFalse);

    await tester.tap(find.byKey(const Key('mic_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice_consent_yes')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(consent.granted, isTrue);
    expect(rec.startCalls, 1);
    expect(find.byKey(const Key('listening_bar')), findsOneWidget);

    // Stop, then tap again: no second dialog.
    await tester.tap(find.byKey(const Key('cancel_listening_button')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('mic_button')));
    await tester.pumpAndSettle();
    expect(find.text('Before you use the microphone'), findsNothing);
    expect(rec.startCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recognized text is previewed with Retry and Discard; nothing is sent automatically',
      (WidgetTester tester) async {
    final FakeRecognizer rec = FakeRecognizer();
    await _boot(tester, rec: rec);
    await tester.tap(find.byKey(const Key('mic_button')));
    await _settle(tester);
    rec.say('sannu Almus', isFinal: true);
    rec.finish();
    await _settle(tester);

    expect(find.byKey(const Key('heard_preview')), findsOneWidget);
    expect(find.byKey(const Key('heard_preview_text')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('chat_input'))).controller!.text, 'sannu Almus');
    expect(find.byKey(const Key('send_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice_retry')));
    await _settle(tester);
    expect(rec.startCalls, 2);
    rec.say('sannu', isFinal: true);
    rec.finish();
    await _settle(tester);
    await tester.tap(find.byKey(const Key('voice_discard')));
    await _settle(tester);
    expect(find.byKey(const Key('heard_preview')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('chat_input'))).controller!.text, '');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('voice language can be switched from the composer', (WidgetTester tester) async {
    final FakeRecognizer rec = FakeRecognizer();
    await _boot(tester, rec: rec);
    expect(find.text('EN'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice_language_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('only if your phone supports it'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice_language_ha')));
    await tester.pumpAndSettle();
    expect(find.text('HA'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
