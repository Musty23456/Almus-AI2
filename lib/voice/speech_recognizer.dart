import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_settings.dart';

/// Why speech recognition could not start or stopped.
enum RecognizerProblem {
  /// The user refused (or permanently blocked) the microphone permission.
  permissionDenied,

  /// No speech-recognition service is installed / enabled on this phone.
  unavailable,

  /// The selected language has no recognition locale on this phone.
  languageUnsupported,

  /// Nothing was heard before the engine gave up.
  noSpeech,

  /// The engine is busy (another app is using it).
  busy,

  /// Network needed by the engine is not reachable.
  network,

  /// Anything else.
  other,
}

/// Outcome of preparing the recognizer.
class RecognizerInit {
  const RecognizerInit.ready(this.localeId)
      : ok = true,
        problem = null;
  const RecognizerInit.failed(this.problem)
      : ok = false,
        localeId = null;

  final bool ok;
  final RecognizerProblem? problem;

  /// Engine locale chosen for the requested language (when [ok]).
  final String? localeId;
}

/// Speech-to-text engine. Implemented by [PlatformSpeechRecognizer] on
/// Android; tests use a fake. Audio never reaches this app: the Android
/// recognition service listens and only text is returned.
abstract class SpeechRecognizerService {
  /// Checks the engine, asks for microphone permission when it has not been
  /// granted yet (the system dialog), and finds a locale for [language].
  /// Must never throw.
  Future<RecognizerInit> prepare(VoiceLanguage language);

  /// Opens the microphone. Must only be called after a successful [prepare].
  /// [onText] receives partial and final text. [onDone] fires once when the
  /// session ends for any reason (after [onProblem] when it ended with one).
  Future<void> start({
    required String localeId,
    required void Function(String text, bool isFinal) onText,
    required void Function(RecognizerProblem problem) onProblem,
    required void Function() onDone,
  });

  /// Stops listening and delivers what was heard so far.
  Future<void> stop();

  /// Stops listening and discards what was heard.
  Future<void> cancel();

  /// Releases native resources (best effort).
  void dispose();
}

/// Android implementation backed by the `speech_to_text` package.
class PlatformSpeechRecognizer implements SpeechRecognizerService {
  PlatformSpeechRecognizer({SpeechToText? engine}) : _engine = engine;

  SpeechToText? _engine;
  bool _initialized = false;
  bool _initOk = false;
  bool _permissionDenied = false;

  // Current session callbacks.
  void Function(RecognizerProblem problem)? _onProblem;
  void Function()? _onDone;
  bool _sessionOpen = false;

  SpeechToText get _stt => _engine ??= SpeechToText();

  @override
  Future<RecognizerInit> prepare(VoiceLanguage language) async {
    try {
      if (!_initialized || !_initOk) {
        _initialized = true;
        _permissionDenied = false;
        // initialize() shows the Android microphone dialog the first time.
        _initOk = await _stt.initialize(
          onError: _handleError,
          onStatus: _handleStatus,
        );
        if (!_initOk) {
          _permissionDenied = !_stt.hasPermission;
        }
      }
      if (!_initOk) {
        return RecognizerInit.failed(
          _permissionDenied
              ? RecognizerProblem.permissionDenied
              : RecognizerProblem.unavailable,
        );
      }
      final List<LocaleName> locales = await _stt.locales();
      final String? id = pickLocale(
        language,
        locales.map((LocaleName l) => l.localeId).toList(),
        (await _stt.systemLocale())?.localeId,
      );
      if (id == null) {
        return const RecognizerInit.failed(RecognizerProblem.languageUnsupported);
      }
      return RecognizerInit.ready(id);
    } on Exception {
      return const RecognizerInit.failed(RecognizerProblem.unavailable);
    }
  }

  /// Chooses an engine locale for [language] from the ones the engine offers.
  /// Returns null when the engine has none (never silently falls back to a
  /// different language). Visible for testing.
  static String? pickLocale(
    VoiceLanguage language,
    List<String> available, [
    String? systemLocale,
  ]) {
    String lang(String id) =>
        id.toLowerCase().replaceAll('-', '_').split('_').first;
    final List<String> matches = available
        .where((String id) => lang(id) == language.code)
        .toList();
    if (matches.isEmpty) return null;
    if (systemLocale != null && lang(systemLocale) == language.code) {
      for (final String id in matches) {
        if (id.toLowerCase().replaceAll('-', '_') ==
            systemLocale.toLowerCase().replaceAll('-', '_')) {
          return id;
        }
      }
    }
    if (language == VoiceLanguage.english) {
      for (final String preferred in <String>['en_us', 'en_gb', 'en_ng']) {
        for (final String id in matches) {
          if (id.toLowerCase().replaceAll('-', '_') == preferred) return id;
        }
      }
    }
    if (language == VoiceLanguage.hausa) {
      for (final String id in matches) {
        if (id.toLowerCase().replaceAll('-', '_') == 'ha_ng') return id;
      }
    }
    return matches.first;
  }

  @override
  Future<void> start({
    required String localeId,
    required void Function(String text, bool isFinal) onText,
    required void Function(RecognizerProblem problem) onProblem,
    required void Function() onDone,
  }) async {
    _onProblem = onProblem;
    _onDone = onDone;
    _sessionOpen = true;
    try {
      await _stt.listen(
        localeId: localeId,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
        onResult: (SpeechRecognitionResult r) =>
            onText(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } on Exception {
      _finish(RecognizerProblem.other);
    }
  }

  void _handleStatus(String status) {
    // 'done' / 'notListening' arrive when the session ends.
    if (status == 'done' || status == 'notListening') {
      _finish(null);
    }
  }

  void _handleError(SpeechRecognitionError e) {
    _finish(mapError(e.errorMsg));
  }

  /// Maps the engine's error text to a [RecognizerProblem].
  static RecognizerProblem mapError(String msg) {
    final String m = msg.toLowerCase();
    if (m.contains('permission')) return RecognizerProblem.permissionDenied;
    if (m.contains('no_match') || m.contains('speech_timeout')) {
      return RecognizerProblem.noSpeech;
    }
    if (m.contains('busy')) return RecognizerProblem.busy;
    if (m.contains('network')) return RecognizerProblem.network;
    if (m.contains('language')) return RecognizerProblem.languageUnsupported;
    return RecognizerProblem.other;
  }

  void _finish(RecognizerProblem? problem) {
    if (!_sessionOpen) return;
    _sessionOpen = false;
    final void Function(RecognizerProblem)? onProblem = _onProblem;
    final void Function()? onDone = _onDone;
    _onProblem = null;
    _onDone = null;
    if (problem != null) onProblem?.call(problem);
    onDone?.call();
  }

  @override
  Future<void> stop() async {
    try {
      await _stt.stop();
    } on Exception {
      _finish(null);
    }
  }

  @override
  Future<void> cancel() async {
    // Detach callbacks first so a cancelled session reports nothing.
    _sessionOpen = false;
    _onProblem = null;
    _onDone = null;
    try {
      await _stt.cancel();
    } on Exception {
      // Nothing to clean up.
    }
  }

  @override
  void dispose() {
    _sessionOpen = false;
    _onProblem = null;
    _onDone = null;
    final SpeechToText? engine = _engine;
    if (engine != null) {
      unawaited(engine.cancel().catchError((Object _) {}));
    }
  }
}
