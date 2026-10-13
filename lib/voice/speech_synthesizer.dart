import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'voice_settings.dart';

/// Outcome of preparing text-to-speech for a language.
enum SynthesizerStatus {
  /// A voice for the requested language is installed.
  ready,

  /// The engine works but has no voice for the language; the device default
  /// voice will be used (pronunciation may be poor).
  languageMissing,

  /// No text-to-speech engine is available at all.
  unavailable,
}

/// Text-to-speech engine. Implemented by [PlatformSpeechSynthesizer] on
/// Android; tests use a fake.
abstract class SpeechSynthesizerService {
  /// True when the engine can pause and resume. Android supports this only
  /// partly (it depends on the engine and Android version), so the UI offers
  /// Pause only when this is true and falls back to Stop if pausing fails.
  bool get supportsPause;

  /// Prepares the engine and selects [language]. Must never throw.
  Future<SynthesizerStatus> prepare(VoiceLanguage language);

  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);

  /// Starts speaking [text]. Replaces anything already playing.
  Future<void> speak(String text);

  Future<void> stop();

  /// Returns false when pausing is not possible right now.
  Future<bool> pause();

  /// Continues after [pause]. [text] is the text that was playing, because
  /// Android has no native resume: the plugin continues (or, at worst,
  /// restarts) the same text.
  Future<void> resume(String text);

  /// Playback callbacks. Set once by the controller.
  set onStart(void Function() callback);
  set onComplete(void Function() callback);
  set onCancel(void Function() callback);
  set onPause(void Function() callback);
  set onContinue(void Function() callback);
  set onError(void Function(String message) callback);

  void dispose();
}

/// Android implementation backed by the `flutter_tts` package.
class PlatformSpeechSynthesizer implements SpeechSynthesizerService {
  PlatformSpeechSynthesizer({FlutterTts? engine}) : _engine = engine;

  FlutterTts? _engine;
  bool _prepared = false;
  bool _available = false;
  VoiceLanguage? _language;
  SynthesizerStatus _status = SynthesizerStatus.unavailable;

  void Function() _start = () {};
  void Function() _complete = () {};
  void Function() _cancel = () {};
  void Function() _pause = () {};
  void Function() _continue = () {};
  void Function(String) _error = (String _) {};

  FlutterTts get _tts => _engine ??= FlutterTts();

  @override
  bool get supportsPause => true;

  @override
  set onStart(void Function() callback) => _start = callback;
  @override
  set onComplete(void Function() callback) => _complete = callback;
  @override
  set onCancel(void Function() callback) => _cancel = callback;
  @override
  set onPause(void Function() callback) => _pause = callback;
  @override
  set onContinue(void Function() callback) => _continue = callback;
  @override
  set onError(void Function(String message) callback) => _error = callback;

  @override
  Future<SynthesizerStatus> prepare(VoiceLanguage language) async {
    try {
      if (!_prepared) {
        _prepared = true;
        final FlutterTts tts = _tts;
        tts.setStartHandler(() => _start());
        tts.setCompletionHandler(() => _complete());
        tts.setCancelHandler(() => _cancel());
        tts.setPauseHandler(() => _pause());
        tts.setContinueHandler(() => _continue());
        tts.setErrorHandler((dynamic message) => _error('$message'));
        _available = true;
      }
      if (!_available) return SynthesizerStatus.unavailable;
      if (_language == language) return _status;
      final dynamic ok = await _tts.isLanguageAvailable(_tag(language));
      final bool present = ok == true || ok == 1;
      if (present) {
        await _tts.setLanguage(_tag(language));
      }
      _language = language;
      _status =
          present ? SynthesizerStatus.ready : SynthesizerStatus.languageMissing;
      return _status;
    } on Exception {
      _available = false;
      _status = SynthesizerStatus.unavailable;
      return _status;
    }
  }

  static String _tag(VoiceLanguage l) =>
      l == VoiceLanguage.hausa ? 'ha-NG' : 'en-US';

  @override
  Future<void> setRate(double rate) async {
    try {
      await _tts.setSpeechRate(rate);
    } on Exception {
      // Rate is optional.
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    try {
      await _tts.setVolume(volume);
    } on Exception {
      // Volume is optional.
    }
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } on Exception catch (e) {
      _error('$e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } on Exception {
      // Already stopped.
    }
  }

  @override
  Future<bool> pause() async {
    try {
      final dynamic r = await _tts.pause();
      return r == null || r == true || r == 1;
    } on Exception {
      return false;
    }
  }

  @override
  Future<void> resume(String text) => speak(text);

  @override
  void dispose() {
    final FlutterTts? engine = _engine;
    if (engine != null) {
      unawaited(stop());
    }
  }
}
