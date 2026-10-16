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

  /// The engine never reported that it started listening.
  notStarted,

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
  /// [localeId] may be empty, meaning "the engine's default language".
  /// [onListening] fires when the engine really opened the microphone (not
  /// just when the app asked it to).
  Future<void> start({
    required String localeId,
    required void Function(String text, bool isFinal) onText,
    required void Function(RecognizerProblem problem) onProblem,
    required void Function() onDone,
    void Function()? onListening,
  });

  /// Stops listening and delivers what was heard so far.
  Future<void> stop();

  /// Stops listening and discards what was heard.
  Future<void> cancel();

  /// Releases native resources (best effort).
  void dispose();
}

/// Android implementation backed by the `speech_to_text` package.
///
/// Reliability notes (these were the causes of an unreliable microphone):
/// * Android reports "notListening" BEFORE the final result. Ending the
///   session on that status lost the last words, so the session now waits
///   briefly for the final result.
/// * Status events of a cancelled session can arrive after a new session
///   started and used to end the new one at once ("second tap does nothing").
///   Statuses are ignored until this session's own "listening" event.
/// * Some engines return an empty locale list; English then uses the
///   engine's default instead of being reported as "not installed".
/// * If the engine never reports "listening" the session now fails with a
///   clear message instead of showing "listening" forever.
class PlatformSpeechRecognizer implements SpeechRecognizerService {
  PlatformSpeechRecognizer({
    SpeechEngine? engine,
    this.startTimeout = const Duration(seconds: 7),
    this.finalGrace = const Duration(milliseconds: 900),
  }) : _engine = engine;

  /// How long to wait for the engine to open the microphone.
  final Duration startTimeout;

  /// How long to wait for the final result after the engine says it stopped.
  final Duration finalGrace;

  SpeechEngine? _engine;
  bool _initOk = false;
  bool _permissionDenied = false;

  // Current session.
  int _session = 0;
  bool _sessionOpen = false;
  bool _sawListening = false;
  bool _finalSeen = false;
  void Function(RecognizerProblem problem)? _onProblem;
  void Function()? _onDone;
  void Function()? _onListening;
  Timer? _startTimer;
  Timer? _graceTimer;

  SpeechEngine get _stt => _engine ??= SpeechToTextEngine();

  Future<bool> _initialize({required bool intentLookup}) async {
    try {
      return await _stt.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
        intentLookup: intentLookup,
      );
    } on Object {
      return false;
    }
  }

  @override
  Future<RecognizerInit> prepare(VoiceLanguage language) async {
    try {
      if (!_initOk) {
        _permissionDenied = false;
        // initialize() shows the Android microphone dialog the first time.
        // "No Bluetooth" avoids an extra Bluetooth permission prompt.
        _initOk = await _initialize(intentLookup: false);
        if (!_initOk) {
          if (await _stt.hasPermission) {
            // Permission is fine, so the engine lookup itself failed. Some
            // phones only find their recognizer through an intent query.
            _initOk = await _initialize(intentLookup: true);
          } else {
            _permissionDenied = true;
          }
        }
      }
      if (!_initOk) {
        return RecognizerInit.failed(
          _permissionDenied
              ? RecognizerProblem.permissionDenied
              : RecognizerProblem.unavailable,
        );
      }
      final List<String> ids = await _stt.localeIds();
      final String? id = pickLocale(language, ids, await _stt.systemLocaleId());
      if (id != null) return RecognizerInit.ready(id);
      if (ids.isEmpty) {
        // The engine did not list its languages. Try anyway: English with the
        // engine default, Hausa by name. If the engine cannot do it, it
        // reports a language error that is explained to the user.
        return RecognizerInit.ready(language == VoiceLanguage.hausa ? 'ha-NG' : '');
      }
      return const RecognizerInit.failed(RecognizerProblem.languageUnsupported);
    } on Object {
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
    void Function()? onListening,
  }) async {
    _clearSession();
    final int mine = ++_session;
    // A previous session that is still winding down would make the engine
    // answer "busy" to a quick second tap.
    try {
      if (_stt.isListening) {
        await _stt.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } on Object {
      // Carry on: listen() reports a real problem if there is one.
    }
    if (mine != _session) return; // cancelled while waiting

    _onProblem = onProblem;
    _onDone = onDone;
    _onListening = onListening;
    _sessionOpen = true;
    _sawListening = false;
    _finalSeen = false;
    _startTimer = Timer(startTimeout, () {
      if (mine == _session && _sessionOpen && !_sawListening) {
        _finish(RecognizerProblem.notStarted, cancelEngine: true);
      }
    });
    try {
      await _stt.listen(
        onResult: (String words, bool isFinal) {
          if (!_sessionOpen || mine != _session) return;
          onText(words, isFinal);
          if (isFinal) {
            _finalSeen = true;
            _finish(null);
          }
        },
        localeId: localeId.isEmpty ? null : localeId,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
      );
    } on Object {
      if (mine == _session) _finish(RecognizerProblem.other);
    }
  }

  void _handleStatus(String status) {
    if (!_sessionOpen) return;
    if (status == 'listening') {
      _sawListening = true;
      _startTimer?.cancel();
      _onListening?.call();
      return;
    }
    // Ignore "done"/"notListening" that belong to an older session.
    if (!_sawListening) return;
    if (status == 'done' || status == 'notListening') {
      if (_finalSeen) {
        _finish(null);
      } else {
        _armGrace(finalGrace);
      }
    }
  }

  void _armGrace(Duration wait) {
    _graceTimer?.cancel();
    _graceTimer = Timer(wait, () => _finish(null));
  }

  void _handleError(String message) {
    if (!_sessionOpen) return;
    _finish(mapError(message));
  }

  /// Maps the engine's error text to a [RecognizerProblem].
  static RecognizerProblem mapError(String msg) {
    final String m = msg.toLowerCase();
    if (m.contains('permission')) return RecognizerProblem.permissionDenied;
    if (m.contains('no_match') || m.contains('speech_timeout')) {
      return RecognizerProblem.noSpeech;
    }
    if (m.contains('busy') || m.contains('too_many')) {
      return RecognizerProblem.busy;
    }
    if (m.contains('network') || m.contains('server')) {
      return RecognizerProblem.network;
    }
    if (m.contains('language')) return RecognizerProblem.languageUnsupported;
    return RecognizerProblem.other;
  }

  void _clearSession() {
    _startTimer?.cancel();
    _graceTimer?.cancel();
    _startTimer = null;
    _graceTimer = null;
    _sessionOpen = false;
    _onProblem = null;
    _onDone = null;
    _onListening = null;
  }

  void _finish(RecognizerProblem? problem, {bool cancelEngine = false}) {
    if (!_sessionOpen) return;
    final void Function(RecognizerProblem)? onProblem = _onProblem;
    final void Function()? onDone = _onDone;
    _clearSession();
    if (cancelEngine) unawaited(_stt.cancel().catchError((Object _) {}));
    if (problem != null) onProblem?.call(problem);
    onDone?.call();
  }

  @override
  Future<void> stop() async {
    // The engine answers with its last words; if it never does, end anyway.
    if (_sessionOpen) _armGrace(const Duration(milliseconds: 2500));
    try {
      await _stt.stop();
    } on Object {
      _finish(null);
    }
  }

  @override
  Future<void> cancel() async {
    // Detach callbacks first so a cancelled session reports nothing.
    _session++;
    _clearSession();
    try {
      await _stt.cancel();
    } on Object {
      // Nothing to clean up.
    }
  }

  @override
  void dispose() {
    _session++;
    _clearSession();
    final SpeechEngine? engine = _engine;
    if (engine != null) {
      unawaited(engine.cancel().catchError((Object _) {}));
    }
  }
}

/// The few engine operations the recognizer needs. A small interface so the
/// session logic (the part that was unreliable) can be tested with a fake
/// engine, without a phone.
abstract class SpeechEngine {
  /// Returns true when the engine is ready. [intentLookup] asks the plugin to
  /// find the recognizer through an intent query (needed on some phones).
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
    required bool intentLookup,
  });

  Future<bool> get hasPermission;
  Future<List<String>> localeIds();
  Future<String?> systemLocaleId();
  bool get isListening;

  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
  });

  Future<void> stop();
  Future<void> cancel();
}

/// [SpeechEngine] backed by the `speech_to_text` plugin (Android system
/// speech recognition). Audio is handled by the phone's speech service.
class SpeechToTextEngine implements SpeechEngine {
  SpeechToTextEngine([SpeechToText? stt]) : _stt = stt ?? SpeechToText();

  final SpeechToText _stt;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
    required bool intentLookup,
  }) {
    return _stt.initialize(
      onError: (SpeechRecognitionError e) => onError(e.errorMsg),
      onStatus: onStatus,
      // "No Bluetooth" avoids an extra Bluetooth permission prompt.
      options: <SpeechConfigOption>[
        SpeechToText.androidNoBluetooth,
        if (intentLookup) SpeechToText.androidIntentLookup,
      ],
    );
  }

  @override
  Future<bool> get hasPermission => _stt.hasPermission;

  @override
  Future<List<String>> localeIds() async =>
      (await _stt.locales()).map((LocaleName l) => l.localeId).toList();

  @override
  Future<String?> systemLocaleId() async => (await _stt.systemLocale())?.localeId;

  @override
  bool get isListening => _stt.isListening;

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
  }) {
    return _stt.listen(
      onResult: (SpeechRecognitionResult r) => onResult(r.recognizedWords, r.finalResult),
      localeId: localeId,
      listenFor: listenFor,
      pauseFor: pauseFor,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  Future<void> cancel() => _stt.cancel();
}
