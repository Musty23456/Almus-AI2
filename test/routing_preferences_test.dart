import 'package:almus_ai/ai/routing_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults are privacy-first: fallback off, nothing shared, nothing sent', () {
    const RoutingPreferences p = RoutingPreferences();
    expect(p.fallbackEnabled, isFalse);
    expect(p.shareMemoryWithFallback, isFalse);
    expect(p.shareFilesWithFallback, isFalse);
    expect(p.isDefault, isTrue);
    expect(p.toRequestJson(), isNull);
  });

  test('sharing flags alone do not make a request carry routing while fallback is off', () {
    const RoutingPreferences p = RoutingPreferences(shareMemoryWithFallback: true);
    expect(p.toRequestJson(), isNull);
  });

  test('request JSON contains provider, models and fallback consent', () {
    const RoutingPreferences p = RoutingPreferences(
      preferredProvider: 'groq',
      models: <String, String>{'groq': 'some-model'},
      fallbackEnabled: true,
      fallbackProviders: <String>{'gemini', 'openrouter'},
      shareMemoryWithFallback: false,
      shareFilesWithFallback: true,
    );
    expect(p.toRequestJson(), <String, Object?>{
      'provider': 'groq',
      'models': <String, String>{'groq': 'some-model'},
      'fallback': <String, Object?>{
        'enabled': true,
        'providers': <String>['gemini', 'openrouter'],
        'shareMemory': false,
        'shareAttachments': true,
      },
    });
  });

  test('fallback with no ticked provider sends an empty allow-list (nothing may receive the message)', () {
    const RoutingPreferences p = RoutingPreferences(fallbackEnabled: true);
    final Map<String, Object?> json = p.toRequestJson()!;
    expect((json['fallback'] as Map<String, Object?>)['providers'], isEmpty);
  });

  test('copyWith can clear the preferred provider', () {
    const RoutingPreferences p = RoutingPreferences(preferredProvider: 'groq');
    expect(p.copyWith(clearPreferredProvider: true).preferredProvider, isNull);
    expect(p.copyWith(fallbackEnabled: true).preferredProvider, 'groq');
  });

  test('JSON round trip and garbage tolerance', () {
    const RoutingPreferences p = RoutingPreferences(
      preferredProvider: 'groq',
      models: <String, String>{'groq': 'm'},
      fallbackEnabled: true,
      fallbackProviders: <String>{'gemini'},
      shareFilesWithFallback: true,
    );
    final RoutingPreferences back = RoutingPreferences.fromJson(p.toJson());
    expect(back.preferredProvider, 'groq');
    expect(back.models, <String, String>{'groq': 'm'});
    expect(back.fallbackEnabled, isTrue);
    expect(back.fallbackProviders, <String>{'gemini'});
    expect(back.shareFilesWithFallback, isTrue);
    expect(RoutingPreferences.fromJson('garbage').isDefault, isTrue);
    expect(RoutingPreferences.fromJson(<String, dynamic>{'fallbackEnabled': 'yes'}).fallbackEnabled, isFalse);
  });

  test('controller applies and persists changes', () async {
    final MemoryRoutingPreferencesStore store = MemoryRoutingPreferencesStore();
    final RoutingPreferencesController c = RoutingPreferencesController(store);
    await c.load();
    expect(c.value.fallbackEnabled, isFalse);
    final bool stored = await c.update(c.value.copyWith(fallbackEnabled: true));
    expect(stored, isTrue);
    expect(c.value.fallbackEnabled, isTrue);
    expect(store.value.fallbackEnabled, isTrue);
    final RoutingPreferencesController again = RoutingPreferencesController(store);
    await again.load();
    expect(again.value.fallbackEnabled, isTrue);
  });
}
