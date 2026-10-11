import 'dart:async';
import 'dart:convert';

import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/routed_chat_service.dart';
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

Future<ChatServiceException> _failure(Future<Object?> future) async {
  try {
    await future;
  } on ChatServiceException catch (e) {
    return e;
  }
  fail('Expected a ChatServiceException');
}

void main() {
  group('BackendClient.chat', () {
    test('sends token and messages, returns the reply', () async {
      late http.Request seen;
      final BackendClient client = BackendClient(
        client: MockClient((http.Request request) async {
          seen = request;
          return _json(200, <String, Object>{'reply': '  Sannu!  '});
        }),
      );

      final String reply = await client.chat(_settings, _messages);

      expect(reply, 'Sannu!');
      expect(seen.url.toString(), 'https://backend.example.com/v1/chat');
      expect(seen.headers['authorization'], 'Bearer tok-123');
      expect(jsonDecode(seen.body), <String, Object>{'messages': _messages});
    });

    test('maps quota errors to the server message', () async {
      final BackendClient client = BackendClient(
        client: MockClient(
          (http.Request _) async => _json(429, <String, Object>{
            'error': <String, Object>{
              'code': 'quota_or_rate_limit',
              'message': 'Gemini rate limit or free-tier quota reached.',
            },
          }),
        ),
      );
      final ChatServiceException e = await _failure(client.chat(_settings, _messages));
      expect(e.code, 'quota_or_rate_limit');
      expect(e.message, contains('quota'));
    });

    test('401 tells the user to check the token', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request _) async => _json(401, <String, Object>{
              'error': <String, Object>{'code': 'unauthorized', 'message': 'x'},
            })),
      );
      final ChatServiceException e = await _failure(client.chat(_settings, _messages));
      expect(e.code, 'unauthorized');
      expect(e.message, contains('token'));
    });

    test('non-JSON server errors get a friendly message', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request _) async => http.Response('<html>Bad gateway</html>', 502)),
      );
      final ChatServiceException e = await _failure(client.chat(_settings, _messages));
      expect(e.code, 'server_error');
      expect(e.message, isNot(contains('<html>')));
    });

    test('network failures are reported as network errors', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request _) async => throw http.ClientException('no route')),
      );
      final ChatServiceException e = await _failure(client.chat(_settings, _messages));
      expect(e.code, 'network');
    });

    test('slow backends time out', () async {
      final BackendClient client = BackendClient(
        timeout: const Duration(milliseconds: 50),
        client: MockClient((http.Request _) => Completer<http.Response>().future),
      );
      final ChatServiceException e = await _failure(client.chat(_settings, _messages));
      expect(e.code, 'timeout');
    });

    test('invalid or empty replies are rejected', () async {
      for (final http.Response response in <http.Response>[
        http.Response('not json', 200),
        _json(200, <String, Object>{'reply': ''}),
        _json(200, <String, Object>{'other': 1}),
      ]) {
        final BackendClient client =
            BackendClient(client: MockClient((http.Request _) async => response));
        final ChatServiceException e = await _failure(client.chat(_settings, _messages));
        expect(e.code, 'invalid_response');
      }
    });
  });

  group('BackendClient.checkConnection', () {
    test('reports the configured model', () async {
      final BackendClient client = BackendClient(
        client: MockClient((http.Request request) async {
          if (request.url.path == '/health') {
            return _json(200, <String, Object>{'status': 'ok', 'geminiConfigured': true});
          }
          expect(request.headers['authorization'], 'Bearer tok-123');
          return _json(200, <String, Object?>{
            'configuredModel': 'gemini-test',
            'fallbackModel': null,
            'models': <String>['gemini-test'],
          });
        }),
      );
      final ConnectionInfo info = await client.checkConnection(_settings);
      expect(info.model, 'gemini-test');
    });

    test('detects a backend without a Gemini key', () async {
      final BackendClient client = BackendClient(
        client: MockClient(
          (http.Request _) async => _json(200, <String, Object>{'status': 'ok', 'geminiConfigured': false}),
        ),
      );
      final ChatServiceException e = await _failure(client.checkConnection(_settings));
      expect(e.code, 'server_not_configured');
    });
  });

  group('settings helpers', () {
    test('normalizeBackendUrl accepts https and trims slashes', () {
      expect(normalizeBackendUrl(' https://a.onrender.com/ '), 'https://a.onrender.com');
      expect(normalizeBackendUrl('https://a.example.com/api//'), 'https://a.example.com/api');
    });

    test('normalizeBackendUrl rejects unsafe or malformed values', () {
      for (final String bad in <String>[
        '',
        'a.onrender.com',
        'http://a.example.com',
        'ftp://a.example.com',
        'https://',
        'https://a.example.com?x=1',
      ]) {
        expect(normalizeBackendUrl(bad), isNull, reason: bad);
      }
    });

    test('AppSettings.isConfigured depends on the URL', () {
      expect(const AppSettings().isConfigured, isFalse);
      expect(_settings.isConfigured, isTrue);
    });
  });

  group('buildChatPayload', () {
    ChatMessage msg(String text, MessageSender who, {bool error = false}) => ChatMessage(
          id: text,
          text: text,
          sender: who,
          timestamp: DateTime(2026),
          isError: error,
        );

    test('includes history, skips error bubbles, ends with the new message', () {
      final List<Map<String, String>> payload = buildChatPayload('now', <ChatMessage>[
        msg('q1', MessageSender.user),
        msg('a1', MessageSender.assistant),
        msg('oops', MessageSender.assistant, error: true),
      ]);
      expect(payload.map((Map<String, String> m) => m['content']), <String>['q1', 'a1', 'now']);
      expect(payload.last['role'], 'user');
    });

    test('limits the number of messages and the total size', () {
      final List<ChatMessage> history = List<ChatMessage>.generate(
        40,
        (int i) => msg('m$i', i.isEven ? MessageSender.user : MessageSender.assistant),
      );
      expect(buildChatPayload('now', history).length, kMaxHistoryMessages);

      final List<ChatMessage> big = <ChatMessage>[
        for (int i = 0; i < 6; i++) msg('x' * 3500, MessageSender.user),
      ];
      final List<Map<String, String>> trimmed = buildChatPayload('now', big);
      final int total = trimmed.fold<int>(0, (int s, Map<String, String> m) => s + m['content']!.length);
      expect(total <= kMaxContextChars, isTrue);
      expect(trimmed.last['content'], 'now');
    });

    test('long assistant messages are shortened', () {
      final List<Map<String, String>> payload = buildChatPayload('now', <ChatMessage>[
        msg('y' * 9000, MessageSender.assistant),
      ]);
      expect(payload.first['content']!.length, kMaxMessageChars);
    });
  });
}
