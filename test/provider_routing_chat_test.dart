import 'dart:convert';

import 'package:almus_ai/ai/routing_preferences.dart';
import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/controllers/settings_controller.dart';
import 'package:almus_ai/data/memory_conversation_repository.dart';
import 'package:almus_ai/models/app_settings.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/services/backend_client.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/routed_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

Future<SettingsController> _liveSettings() async {
  final SettingsController c = SettingsController(
    MemorySettingsStore(const AppSettings(backendUrl: 'https://b.example.com', accessToken: 't')),
  );
  await c.load();
  return c;
}

void main() {
  test('RoutedChatService adds the user routing choices to live requests', () async {
    late Map<String, dynamic> body;
    final RoutingPreferencesController routing = RoutingPreferencesController(MemoryRoutingPreferencesStore());
    await routing.update(const RoutingPreferences(
      fallbackEnabled: true,
      fallbackProviders: <String>{'groq'},
    ));
    final RoutedChatService service = RoutedChatService(
      settings: await _liveSettings(),
      backend: BackendClient(
        client: MockClient((http.Request r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return _json(200, <String, Object?>{
            'reply': 'hi',
            'provider': 'groq',
            'providerName': 'Groq',
            'route': <String, Object?>{'fallbackUsed': true, 'failed': <Object>[], 'omitted': <String>['memory']},
          });
        }),
      ),
      routing: routing,
    );
    expect(await service.reply('hello'), 'hi');
    expect((body['routing'] as Map<String, dynamic>)['fallback'], isNotNull);
    expect(service.lastProvenance!.providerId, 'groq');
    expect(service.lastProvenance!.fallbackUsed, isTrue);
  });

  test('without customised routing nothing extra is sent and provenance is cleared', () async {
    late Map<String, dynamic> body;
    final RoutedChatService service = RoutedChatService(
      settings: await _liveSettings(),
      backend: BackendClient(
        client: MockClient((http.Request r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return _json(200, <String, Object>{'reply': 'plain'});
        }),
      ),
      routing: RoutingPreferencesController(MemoryRoutingPreferencesStore()),
    );
    await service.reply('hello');
    expect(body.containsKey('routing'), isFalse);
    expect(service.lastProvenance, isNull);
  });

  test('demo mode never contacts a provider and has no provenance', () async {
    final RoutedChatService service = RoutedChatService(
      settings: SettingsController(MemorySettingsStore()),
      backend: BackendClient(client: MockClient((http.Request _) async => fail('no network in demo mode'))),
      demo: DemoChatService(thinkingDelay: Duration.zero),
    );
    expect(service.isDemo, isTrue);
    await service.reply('hello');
    expect(service.lastProvenance, isNull);
  });

  group('ChatController', () {
    test('labels a reply with the provider that answered and explains a fallback', () async {
      final _ProvenanceService service = _ProvenanceService(
        const ReplyProvenance(
          providerId: 'groq',
          providerName: 'Groq',
          fallbackUsed: true,
          failedProviders: <String>['gemini'],
          omitted: <String>['memory'],
        ),
      );
      final ChatController chat = ChatController(service: service, repository: MemoryConversationRepository());
      addTearDown(chat.dispose);
      await chat.send('hello');
      expect(chat.messages.last.engineLabel, 'GROQ');
      expect(chat.routeNotice, contains('Groq'));
      expect(chat.routeNotice, contains('gemini'));
      expect(chat.routeNotice, contains('memory notes were not shared'));
      chat.newConversation();
      expect(chat.routeNotice, isNull);
    });

    test('no notice when the usual provider answered; label stays GEMINI without provenance', () async {
      final ChatController plain = ChatController(service: _ProvenanceService(null), repository: MemoryConversationRepository());
      addTearDown(plain.dispose);
      await plain.send('hello');
      expect(plain.messages.last.engineLabel, 'GEMINI');
      expect(plain.routeNotice, isNull);

      final ChatController primary = ChatController(
        service: _ProvenanceService(const ReplyProvenance(providerId: 'groq', providerName: 'Groq')),
        repository: MemoryConversationRepository(),
      );
      addTearDown(primary.dispose);
      await primary.send('hello');
      expect(primary.messages.last.engineLabel, 'GROQ');
      expect(primary.routeNotice, isNull);
    });
  });
}

/// A live-looking engine that reports a fixed provenance.
class _ProvenanceService implements ChatService, ReplyProvenanceSource {
  _ProvenanceService(this._provenance);

  final ReplyProvenance? _provenance;

  @override
  ReplyProvenance? get lastProvenance => _provenance;

  @override
  bool get isDemo => false;

  @override
  String get engineName => 'LIVE';

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async =>
      'answer';
}
