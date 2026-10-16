import 'dart:convert';

import 'package:almus_ai/ai/provider_status_controller.dart';
import 'package:almus_ai/ai/routing_preferences.dart';
import 'package:almus_ai/controllers/settings_controller.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/screens/ai_providers_screen.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

Map<String, Object?> _prov(String id, String name, {bool configured = true, String state = 'unknown', bool verified = false, String cost = 'unknown', String? model}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'configured': configured,
      'state': configured ? state : 'unconfigured',
      'verified': verified,
      'costPolicy': cost,
      'fallbackEligible': true,
      'model': model,
      'modelSource': model == null ? 'none' : 'configured',
      'capabilities': <String, Object?>{'text': true, 'extractedTextAttachments': true, 'images': false},
      'dataNote': '$name data note.',
      'limitsNote': '',
    };

Map<String, Object?> _snapshot({String groqCost = 'unknown', bool allowPaid = false}) => <String, Object?>{
      'primaryDefault': 'gemini',
      'allowPaidFallback': allowPaid,
      'fallbackOrder': <String>['groq'],
      'providers': <Map<String, Object?>>[
        _prov('gemini', 'Google Gemini', model: 'gemini-flash-latest', cost: 'free_only'),
        _prov('groq', 'Groq', cost: groqCost, model: 'groq-chat'),
        _prov('openrouter', 'OpenRouter', configured: false),
      ],
    };

class _Harness {
  _Harness(this.settings, this.status, this.routing);

  final SettingsController settings;
  final ProviderStatusController status;
  final RoutingPreferencesController routing;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool configured = true,
  Map<String, Object?>? snapshot,
  http.Response Function(http.Request)? handler,
}) async {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final SettingsController settings = SettingsController(
    MemorySettingsStore(configured ? const AppSettings(backendUrl: 'https://b.example.com', accessToken: 't') : const AppSettings()),
  );
  await settings.load();
  final BackendClient backend = BackendClient(
    client: MockClient((http.Request r) async {
      if (handler != null) return handler(r);
      if (r.url.path == '/v1/providers' && r.method == 'GET') return _json(200, snapshot ?? _snapshot());
      if (r.url.path == '/v1/providers/check') {
        return _json(200, <String, Object?>{
          'providers': <Map<String, Object?>>[
            _prov('gemini', 'Google Gemini', state: 'healthy', verified: true, cost: 'free_only', model: 'gemini-flash-latest'),
            _prov('groq', 'Groq', state: 'misconfigured', model: 'groq-chat'),
          ],
        });
      }
      if (r.url.path == '/v1/providers/groq/models') {
        return _json(200, <String, Object?>{
          'provider': 'groq',
          'models': <Map<String, Object?>>[
            <String, Object?>{'id': 'groq-chat', 'contextTokens': 131072},
          ],
        });
      }
      return _json(404, <String, Object>{'error': <String, Object>{'code': 'not_found', 'message': 'nope'}});
    }),
  );
  final ProviderStatusController status = ProviderStatusController(backend: backend, settings: settings);
  final RoutingPreferencesController routing = RoutingPreferencesController(MemoryRoutingPreferencesStore());
  addTearDown(status.dispose);
  await tester.pumpWidget(
    MaterialApp(home: AiProvidersScreen(settings: settings, status: status, routing: routing)),
  );
  await tester.pumpAndSettle();
  return _Harness(settings, status, routing);
}

void main() {
  testWidgets('explains local versus remote processing', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('processing_title')), findsOneWidget);
    expect(find.text('AI answers are processed remotely'), findsOneWidget);
    final Text local = tester.widget<Text>(find.byKey(const Key('local_features_text')));
    expect(local.data, contains('Backup export and import'));
    expect(local.data, contains('editing memory'));
    expect(find.text('REMOTE'), findsWidgets);
  });

  testWidgets('demo mode: everything is local and no provider is listed', (WidgetTester tester) async {
    await _pump(tester, configured: false);
    expect(find.text('DEMO MODE: everything stays on this phone'), findsOneWidget);
    expect(find.byKey(const Key('check_providers_button')), findsNothing);
    expect(find.byKey(const Key('provider_card_gemini')), findsNothing);
  });

  testWidgets('a configured provider is "not checked yet" until a real check; nothing claims it works', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.text('Not checked yet'), findsNWidgets(2));
    expect(find.textContaining('Working'), findsNothing);
    expect(find.text('Not configured on your server'), findsOneWidget);
    expect(find.textContaining('Add its key on your backend'), findsOneWidget);

    await tester.tap(find.byKey(const Key('check_providers_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Working (confirmed'), findsOneWidget);
    expect(find.text('Needs attention on the server (key or model)'), findsOneWidget);
  });

  testWidgets('shows cost and capability facts, including "no images"', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.text('Free models only (as declared by your server)'), findsOneWidget);
    expect(find.text('Cost not declared: could be free or paid'), findsOneWidget);
    expect(find.text('No images'), findsWidgets);
    expect(find.text('File text'), findsWidgets);
    expect(find.text('Model: gemini-flash-latest'), findsOneWidget);
  });

  testWidgets('automatic fallback is off by default and says nothing goes elsewhere', (WidgetTester tester) async {
    final _Harness h = await _pump(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('fallback_switch'))).value, isFalse);
    expect(find.byKey(const Key('fallback_off_note')), findsOneWidget);
    expect(find.byKey(const Key('fallback_provider_groq')), findsNothing);
    expect(h.routing.value.fallbackEnabled, isFalse);
    expect(h.routing.value.toRequestJson(), isNull);
  });

  testWidgets('a provider not declared free-only cannot be ticked as fallback', (WidgetTester tester) async {
    final _Harness h = await _pump(tester);
    await tester.tap(find.byKey(const Key('fallback_switch')));
    await tester.pumpAndSettle();
    expect(h.routing.value.fallbackEnabled, isTrue);
    final CheckboxListTile box = tester.widget<CheckboxListTile>(find.byKey(const Key('fallback_provider_groq')));
    expect(box.onChanged, isNull);
    expect(find.textContaining('not declared free-only'), findsOneWidget);
    expect(h.routing.value.fallbackProviders, isEmpty);
  });

  testWidgets('user can allow a free-only provider; memory and file sharing stay off until chosen', (WidgetTester tester) async {
    final _Harness h = await _pump(tester, snapshot: _snapshot(groqCost: 'free_only'));
    await tester.tap(find.byKey(const Key('fallback_switch')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('share_memory_switch'))).value, isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('share_files_switch'))).value, isFalse);
    await tester.tap(find.byKey(const Key('fallback_provider_groq')));
    await tester.pumpAndSettle();
    expect(h.routing.value.fallbackProviders, <String>{'groq'});
    final Map<String, Object?> json = h.routing.value.toRequestJson()!;
    expect((json['fallback'] as Map<String, Object?>)['providers'], <String>['groq']);
    expect((json['fallback'] as Map<String, Object?>)['shareMemory'], false);
    await tester.tap(find.byKey(const Key('share_memory_switch')));
    await tester.pumpAndSettle();
    expect(h.routing.value.shareMemoryWithFallback, isTrue);
  });

  testWidgets('choosing a different main provider updates the routing', (WidgetTester tester) async {
    final _Harness h = await _pump(tester);
    expect(h.routing.value.preferredProvider, isNull);
    await tester.tap(find.byKey(const Key('main_groq')));
    await tester.pumpAndSettle();
    expect(h.routing.value.preferredProvider, 'groq');
    await tester.tap(find.byKey(const Key('main_default')));
    await tester.pumpAndSettle();
    expect(h.routing.value.preferredProvider, isNull);
  });

  testWidgets('model chooser lists the provider live models and stores the choice', (WidgetTester tester) async {
    final _Harness h = await _pump(tester);
    await tester.tap(find.byKey(const Key('choose_model_groq')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model_groq-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('model_groq-chat')));
    await tester.pumpAndSettle();
    expect(h.routing.value.models, <String, String>{'groq': 'groq-chat'});
    expect(find.text('Model: groq-chat (your choice)'), findsOneWidget);
  });

  testWidgets('a backend error is shown without breaking the screen', (WidgetTester tester) async {
    await _pump(
      tester,
      handler: (http.Request _) => _json(503, <String, Object>{'error': <String, Object>{'code': 'upstream_unavailable', 'message': 'Backend is waking up.'}}),
    );
    expect(find.byKey(const Key('providers_error')), findsOneWidget);
    expect(find.byKey(const Key('processing_title')), findsOneWidget);
    expect(find.byKey(const Key('local_features_text')), findsOneWidget);
  });
}
