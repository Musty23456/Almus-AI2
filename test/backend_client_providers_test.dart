import 'dart:convert';

import 'package:almus_ai/ai/provider_info.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const AppSettings _settings = AppSettings(
  backendUrl: 'https://backend.example.com',
  accessToken: 'tok-123',
);

final List<Map<String, String>> _messages = <Map<String, String>>[
  <String, String>{'role': 'user', 'content': 'Hello'},
];

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('chat with routing', () {
    test('sends no routing field when nothing was customised', () async {
      late http.Request seen;
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          seen = r;
          return _json(200, <String, Object>{'reply': 'ok'});
        }),
      );
      await client.chat(_settings, _messages, routing: null);
      expect(jsonDecode(seen.body), <String, Object>{'messages': _messages});
    });

    test('sends the routing object and parses which provider answered', () async {
      late http.Request seen;
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          seen = r;
          return _json(200, <String, Object?>{
            'reply': ' from groq ',
            'provider': 'groq',
            'providerName': 'Groq',
            'model': 'm1',
            'route': <String, Object?>{
              'fallbackUsed': true,
              'failed': <Map<String, String>>[
                <String, String>{'provider': 'gemini', 'category': 'quota_exhausted'},
              ],
              'omitted': <String>['memory'],
            },
          });
        }),
      );
      final ChatReply reply = await client.chatWithInfo(
        _settings,
        _messages,
        routing: <String, Object?>{
          'fallback': <String, Object?>{'enabled': true, 'providers': <String>['groq']},
        },
      );
      expect((jsonDecode(seen.body) as Map<String, dynamic>)['routing'], isNotNull);
      expect(reply.text, 'from groq');
      expect(reply.provenance!.providerId, 'groq');
      expect(reply.provenance!.label, 'GROQ');
      expect(reply.provenance!.fallbackUsed, isTrue);
      expect(reply.provenance!.failedProviders, <String>['gemini']);
      expect(reply.provenance!.omitted, <String>['memory']);
    });

    test('an older backend without provider info gives null provenance', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request _) async => _json(200, <String, Object>{'reply': 'hi'})),
      );
      expect((await client.chatWithInfo(_settings, _messages)).provenance, isNull);
    });

    test('a fallback-blocked error keeps the server message', () async {
      final BackendClient client = BackendClient(
        client: MockClient(
          (http.Request _) async => _json(429, <String, Object>{
            'error': <String, Object>{
              'code': 'quota_or_rate_limit',
              'message': 'Gemini has no quota left right now. Automatic fallback is off.',
            },
          }),
        ),
      );
      try {
        await client.chat(_settings, _messages);
        fail('expected an error');
      } on ChatServiceException catch (e) {
        expect(e.code, 'quota_or_rate_limit');
        expect(e.message, contains('fallback is off'));
      }
    });
  });

  group('provider endpoints', () {
    test('listProviders reads GET /v1/providers with the token', () async {
      late http.Request seen;
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          seen = r;
          return _json(200, <String, Object?>{
            'primaryDefault': 'gemini',
            'providers': <Map<String, Object?>>[
              <String, Object?>{'id': 'gemini', 'name': 'Google Gemini', 'configured': true, 'state': 'unknown', 'verified': false},
            ],
          });
        }),
      );
      final ProvidersSnapshot snap = await client.listProviders(_settings);
      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/providers');
      expect(seen.headers['authorization'], 'Bearer tok-123');
      expect(snap.byId('gemini')!.verified, isFalse);
    });

    test('checkProviders POSTs the provider id (or an empty object)', () async {
      final List<http.Request> seen = <http.Request>[];
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          seen.add(r);
          return _json(200, <String, Object?>{'providers': <Object>[]});
        }),
      );
      await client.checkProviders(_settings);
      await client.checkProviders(_settings, providerId: 'groq');
      expect(seen[0].url.path, '/v1/providers/check');
      expect(jsonDecode(seen[0].body), <String, Object>{});
      expect(jsonDecode(seen[1].body), <String, Object>{'provider': 'groq'});
    });

    test('listProviderModels parses the live list', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          expect(r.url.path, '/v1/providers/groq/models');
          return _json(200, <String, Object?>{
            'provider': 'groq',
            'models': <Map<String, Object?>>[
              <String, Object?>{'id': 'a', 'contextTokens': 131072, 'free': null},
              <String, Object?>{'id': 'b'},
            ],
          });
        }),
      );
      final List<ProviderModel> models = await client.listProviderModels(_settings, 'groq');
      expect(models.map((ProviderModel m) => m.id), <String>['a', 'b']);
      expect(models.first.contextTokens, 131072);
    });

    test('checkConnection works for a backend that uses another provider', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request r) async {
          if (r.url.path == '/health') {
            return _json(200, <String, Object>{'status': 'ok', 'geminiConfigured': false, 'aiConfigured': true});
          }
          return _json(200, <String, Object?>{
            'primaryDefault': 'groq',
            'providers': <Map<String, Object?>>[
              <String, Object?>{'id': 'groq', 'name': 'Groq', 'configured': true, 'state': 'unknown', 'verified': false, 'model': 'chosen-model'},
            ],
          });
        }),
      );
      expect((await client.checkConnection(_settings)).model, 'chosen-model');
    });

    test('a backend with no provider at all is reported', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request _) async => _json(200, <String, Object>{'status': 'ok', 'geminiConfigured': false, 'aiConfigured': false})),
      );
      try {
        await client.checkConnection(_settings);
        fail('expected an error');
      } on ChatServiceException catch (e) {
        expect(e.code, 'server_not_configured');
      }
    });
  });
}
