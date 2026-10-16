import 'package:almus_ai/ai/provider_info.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _provider(Map<String, dynamic> over) => <String, dynamic>{
      'id': 'groq',
      'name': 'Groq',
      'configured': true,
      'state': 'unknown',
      'verified': false,
      ...over,
    };

void main() {
  test('parses a backend snapshot', () {
    final ProvidersSnapshot snap = ProvidersSnapshot.fromJson(<String, dynamic>{
      'primaryDefault': 'gemini',
      'allowPaidFallback': false,
      'fallbackOrder': <String>['groq'],
      'providers': <Map<String, dynamic>>[
        _provider(<String, dynamic>{
          'id': 'gemini',
          'name': 'Google Gemini',
          'state': 'healthy',
          'verified': true,
          'lastCheckedAt': '2026-10-15T10:30:00.000Z',
          'model': 'gemini-flash-latest',
          'modelSource': 'configured',
          'costPolicy': 'free_only',
          'capabilities': <String, dynamic>{
            'text': true,
            'extractedTextAttachments': true,
            'images': false,
            'maxInputTokens': 6000,
          },
        }),
        _provider(<String, dynamic>{'id': 'openrouter', 'configured': false, 'state': 'unconfigured'}),
      ],
    });
    expect(snap.primaryDefault, 'gemini');
    expect(snap.providers, hasLength(2));
    final ProviderInfo g = snap.byId('gemini')!;
    expect(g.state, ProviderState.healthy);
    expect(g.verified, isTrue);
    expect(g.capabilities.maxInputTokens, 6000);
    expect(g.capabilities.images, isFalse);
    expect(g.costPolicy, 'free_only');
    expect(snap.byId('openrouter')!.configured, isFalse);
    expect(snap.byId('missing'), isNull);
  });

  test('tolerates missing and malformed fields', () {
    final ProvidersSnapshot snap = ProvidersSnapshot.fromJson(<String, dynamic>{'providers': 'nope'});
    expect(snap.providers, isEmpty);
    final ProviderInfo p = ProviderInfo.fromJson(<String, dynamic>{'id': 'x', 'state': 'weird'});
    expect(p.state, ProviderState.unknown);
    expect(p.verified, isFalse);
    expect(p.capabilities.text, isTrue);
  });

  group('describeProviderState never overstates', () {
    ProviderInfo info(Map<String, dynamic> over) => ProviderInfo.fromJson(_provider(over));

    test('configured but unchecked is "not checked yet"', () {
      expect(describeProviderState(info(<String, dynamic>{})), 'Not checked yet');
    });

    test('healthy without verification is still "not checked yet"', () {
      expect(
        describeProviderState(info(<String, dynamic>{'state': 'healthy', 'verified': false})),
        'Not checked yet',
      );
    });

    test('only a verified healthy provider is called working', () {
      final String text = describeProviderState(
        info(<String, dynamic>{'state': 'healthy', 'verified': true, 'lastCheckedAt': '2026-10-15T10:30:00.000Z'}),
      );
      expect(text, startsWith('Working (confirmed'));
    });

    test('problem states are described plainly', () {
      expect(describeProviderState(info(<String, dynamic>{'state': 'rate_limited', 'retryAfterSeconds': 12})), contains('12s'));
      expect(describeProviderState(info(<String, dynamic>{'state': 'quota_exhausted'})), contains('Quota'));
      expect(describeProviderState(info(<String, dynamic>{'state': 'unavailable'})), contains('unavailable'));
      expect(describeProviderState(info(<String, dynamic>{'state': 'misconfigured'})), contains('server'));
      expect(describeProviderState(info(<String, dynamic>{'state': 'unconfigured', 'configured': false})), contains('Not configured'));
      expect(describeProviderState(info(<String, dynamic>{'state': 'degraded'})), contains('Not confirmed'));
    });

    test('no non-healthy state ever says "working" or "available"', () {
      for (final String s in <String>['unknown', 'degraded', 'rate_limited', 'quota_exhausted', 'unavailable', 'misconfigured', 'unconfigured']) {
        final String text = describeProviderState(info(<String, dynamic>{'state': s, 'verified': true})).toLowerCase();
        expect(text.contains('working'), isFalse, reason: s);
        expect(text.startsWith('available'), isFalse, reason: s);
      }
    });
  });
}
