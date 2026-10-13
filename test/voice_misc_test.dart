import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/speech_text.dart';
import 'package:almus_ai/voice/voice_controller.dart';
import 'package:almus_ai/voice/voice_settings.dart';
import 'package:almus_ai/voice/voice_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SpeechText.clean', () {
    test('removes markdown emphasis, headings and bullets', () {
      expect(
        SpeechText.clean('# Title\n\n- **Bold** point\n- *italic* point'),
        'Title Bold point italic point',
      );
    });

    test('drops code blocks and keeps inline code words', () {
      expect(
        SpeechText.clean('Run `flutter test` now.\n```\nrm -rf /\n```\nDone.'),
        'Run flutter test now. Done.',
      );
    });

    test('drops an unterminated code block', () {
      expect(SpeechText.clean('Before\n```\nnever closed'), 'Before');
    });

    test('keeps link text, removes the address', () {
      expect(
        SpeechText.clean('Read [the docs](https://example.com/a?b=c) first'),
        'Read the docs first',
      );
      expect(SpeechText.clean('Visit https://example.com now'), 'Visit now');
    });

    test('keeps Hausa text and punctuation intact', () {
      expect(
        SpeechText.clean('Sannu! Yaya aiki? Ina lafiya.'),
        'Sannu! Yaya aiki? Ina lafiya.',
      );
    });

    test('empty or symbol-only text becomes empty', () {
      expect(SpeechText.clean(''), '');
      expect(SpeechText.clean('  ***  ---  '), '');
      expect(SpeechText.clean('```x```'), '');
    });

    test('very long text is cut at a sentence boundary', () {
      final String long = List<String>.filled(900, 'Hello there.').join(' ');
      final String cleaned = SpeechText.clean(long);
      expect(cleaned.length, lessThanOrEqualTo(SpeechText.maxChars));
      expect(cleaned.endsWith('.'), isTrue);
    });
  });

  group('PlatformSpeechRecognizer.pickLocale', () {
    const List<String> locales = <String>[
      'en_US',
      'en_GB',
      'fr_FR',
      'ha_NG',
      'ha-GH',
    ];

    test('picks English variants, preferring en_US', () {
      expect(
        PlatformSpeechRecognizer.pickLocale(VoiceLanguage.english, locales),
        'en_US',
      );
    });

    test('prefers the system locale when it is English', () {
      expect(
        PlatformSpeechRecognizer.pickLocale(
          VoiceLanguage.english,
          locales,
          'en-GB',
        ),
        'en_GB',
      );
    });

    test('finds Hausa when the engine offers it', () {
      expect(
        PlatformSpeechRecognizer.pickLocale(VoiceLanguage.hausa, locales),
        'ha_NG',
      );
    });

    test('returns null when Hausa is not offered, never falls back to English',
        () {
      expect(
        PlatformSpeechRecognizer.pickLocale(
          VoiceLanguage.hausa,
          <String>['en_US', 'fr_FR'],
        ),
        isNull,
      );
      expect(
        PlatformSpeechRecognizer.pickLocale(VoiceLanguage.hausa, <String>[]),
        isNull,
      );
    });
  });

  group('PlatformSpeechRecognizer.mapError', () {
    test('maps engine messages to problems', () {
      expect(PlatformSpeechRecognizer.mapError('error_permission'),
          RecognizerProblem.permissionDenied);
      expect(PlatformSpeechRecognizer.mapError('error_no_match'),
          RecognizerProblem.noSpeech);
      expect(PlatformSpeechRecognizer.mapError('error_speech_timeout'),
          RecognizerProblem.noSpeech);
      expect(PlatformSpeechRecognizer.mapError('error_recognizer_busy'),
          RecognizerProblem.busy);
      expect(PlatformSpeechRecognizer.mapError('error_network'),
          RecognizerProblem.network);
      expect(PlatformSpeechRecognizer.mapError('error_language_not_supported'),
          RecognizerProblem.languageUnsupported);
      expect(PlatformSpeechRecognizer.mapError('???'), RecognizerProblem.other);
    });
  });

  group('VoiceController.problemMessage', () {
    test('every problem has a plain-language message, none show codes', () {
      for (final RecognizerProblem p in RecognizerProblem.values) {
        for (final VoiceLanguage l in VoiceLanguage.values) {
          final String m = VoiceController.problemMessage(p, l);
          expect(m, isNotEmpty);
          expect(m, isNot(contains('error_')));
        }
      }
    });
  });

  group('VoiceSettings', () {
    test('defaults', () {
      const VoiceSettings s = VoiceSettings();
      expect(s.autoSpeak, isTrue);
      expect(s.autoSendVoice, isFalse);
      expect(s.language, VoiceLanguage.english);
      expect(s.speechRate, VoiceSettings.defaultRate);
      expect(s.volume, 1.0);
    });

    test('copyWith clamps rate and volume', () {
      final VoiceSettings s =
          const VoiceSettings().copyWith(speechRate: 9, volume: -3);
      expect(s.speechRate, VoiceSettings.maxRate);
      expect(s.volume, 0.0);
      expect(
        const VoiceSettings().copyWith(speechRate: 0.0).speechRate,
        VoiceSettings.minRate,
      );
      expect(
        const VoiceSettings().copyWith(speechRate: double.nan).speechRate,
        VoiceSettings.minRate,
      );
    });

    test('language lookup falls back to English', () {
      expect(VoiceLanguage.fromName('hausa'), VoiceLanguage.hausa);
      expect(VoiceLanguage.fromName('klingon'), VoiceLanguage.english);
      expect(VoiceLanguage.fromName(null), VoiceLanguage.english);
    });

    test('value equality', () {
      expect(const VoiceSettings(), const VoiceSettings());
      expect(
        const VoiceSettings(),
        isNot(const VoiceSettings(autoSpeak: false)),
      );
    });
  });

  group('voice settings storage', () {
    test('preferences round-trip', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PrefsVoiceSettingsStore store = PrefsVoiceSettingsStore();
      expect(await store.load(), const VoiceSettings());

      const VoiceSettings changed = VoiceSettings(
        autoSpeak: false,
        autoSendVoice: true,
        language: VoiceLanguage.hausa,
        speechRate: 0.7,
        volume: 0.3,
      );
      await store.save(changed);
      expect(await PrefsVoiceSettingsStore().load(), changed);
    });

    test('corrupt stored values fall back to safe defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'voice_language': 'nonsense',
        'voice_rate': 99.0,
        'voice_volume': -1.0,
      });
      final VoiceSettings s = await PrefsVoiceSettingsStore().load();
      expect(s.language, VoiceLanguage.english);
      expect(s.speechRate, VoiceSettings.maxRate);
      expect(s.volume, 0.0);
    });

    test('controller applies changes immediately and persists them', () async {
      final MemoryVoiceSettingsStore store = MemoryVoiceSettingsStore();
      final VoiceSettingsController c = VoiceSettingsController(store);
      await c.load();
      final bool ok = await c.save(c.value.copyWith(autoSpeak: false));
      expect(ok, isTrue);
      expect(c.value.autoSpeak, isFalse);
      expect(store.settings.autoSpeak, isFalse);
      c.dispose();
    });

    test('a failing store does not break the controller', () async {
      final VoiceSettingsController c = VoiceSettingsController(_BrokenStore());
      await c.load();
      expect(c.value, const VoiceSettings());
      expect(await c.save(const VoiceSettings(autoSpeak: false)), isFalse);
      expect(c.value.autoSpeak, isFalse, reason: 'applied for this session');
      c.dispose();
    });
  });
}

class _BrokenStore implements VoiceSettingsStore {
  @override
  Future<VoiceSettings> load() async => throw Exception('disk');
  @override
  Future<void> save(VoiceSettings settings) async => throw Exception('disk');
}
