import 'dart:convert';

import 'package:almus_ai/app.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const AppSettings _live = AppSettings(
  backendUrl: 'https://backend.example.com',
  accessToken: 'tok',
);

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _openChat(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.chat_bubble_outline));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat_input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('send_button')));
  await tester.pump();
}

void main() {
  testWidgets('live mode shows a real reply, thinking state and no duplicates',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
    final BackendClient backend = BackendClient(
      client: MockClient((http.Request request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response(
          jsonEncode(<String, String>{'reply': 'Gemini says hi'}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    await tester.pumpWidget(
      AlmusApp(
        showSplash: false,
        settingsStore: MemorySettingsStore(_live),
        backendClient: backend,
      ),
    );
    await tester.pump();
    await _openChat(tester);

    expect(find.textContaining('LIVE MODE'), findsOneWidget);

    await _send(tester, 'hello');
    expect(find.text('THINKING'), findsOneWidget);
    expect(find.textContaining('Almus is thinking'), findsOneWidget);

    // A second submission while waiting must be ignored.
    await tester.enterText(find.byKey(const Key('chat_input')), 'again');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')), warnIfMissed: false);
    await tester.pump();
    expect(bodies.length, 1);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Gemini says hi'), findsOneWidget);
    expect(find.text('ALMUS · GEMINI'), findsOneWidget);
    expect(find.text('TALKING'), findsOneWidget);
    expect(bodies.length, 1);

    await tester.pump(const Duration(seconds: 8));
    expect(find.text('IDLE'), findsOneWidget);
  });

  testWidgets('quota errors are shown in chat and the robot shows error',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final BackendClient backend = BackendClient(
      client: MockClient(
        (http.Request _) async => http.Response(
          jsonEncode(<String, Object>{
            'error': <String, String>{
              'code': 'quota_or_rate_limit',
              'message': 'Gemini rate limit or free-tier quota reached.',
            },
          }),
          429,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    );

    await tester.pumpWidget(
      AlmusApp(
        showSplash: false,
        settingsStore: MemorySettingsStore(_live),
        backendClient: backend,
      ),
    );
    await tester.pump();
    await _openChat(tester);

    await _send(tester, 'hello');
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('ALMUS · ERROR'), findsOneWidget);
    expect(find.textContaining('free-tier quota'), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('without a backend the chat stays in DEMO MODE',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(
      AlmusApp(showSplash: false, settingsStore: MemorySettingsStore()),
    );
    await tester.pump();
    await _openChat(tester);
    expect(find.textContaining('DEMO MODE'), findsWidgets);
    expect(find.textContaining('LIVE MODE'), findsNothing);
  });

  testWidgets('saving a backend in Settings switches chat to live mode',
      (WidgetTester tester) async {
    _usePhoneScreen(tester);
    final MemorySettingsStore store = MemorySettingsStore();
    await tester.pumpWidget(
      AlmusApp(showSplash: false, settingsStore: store),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.byKey(const Key('backend_url_field')),
      'http://not-secure.example.com',
    );
    await tester.tap(find.byKey(const Key('save_connection')));
    await tester.pump();
    expect(find.textContaining('valid https://'), findsOneWidget);
    expect(store.settings.isConfigured, isFalse);

    await tester.enterText(
      find.byKey(const Key('backend_url_field')),
      'https://backend.example.com/',
    );
    await tester.enterText(find.byKey(const Key('access_token_field')), 'secret-token');
    await tester.tap(find.byKey(const Key('save_connection')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Saved'), findsOneWidget);
    expect(store.settings.backendUrl, 'https://backend.example.com');
    expect(store.settings.accessToken, 'secret-token');
    expect(find.text('LIVE (Gemini via backend)'), findsOneWidget);
  });
}
