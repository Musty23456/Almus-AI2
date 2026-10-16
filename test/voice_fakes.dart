import 'dart:async';

import 'package:almus_ai/voice/speech_recognizer.dart';
import 'package:almus_ai/voice/speech_synthesizer.dart';
import 'package:almus_ai/voice/voice_settings.dart';

/// Scriptable speech recognizer: tests decide permission results and drive
/// the "engine" events by hand. No plugin, no microphone.
class FakeRecognizer implements SpeechRecognizerService {
  RecognizerInit initResult = const RecognizerInit.ready('en_US');

  /// When set, [prepare] waits for it (simulates the permission dialog).
  Completer<RecognizerInit>? prepareGate;

  /// When true, [stop] finishes the session like a real engine does.
  bool finishOnStop = true;

  int prepareCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  bool listening = false;
  VoiceLanguage? lastLanguage;
  String? lastLocale;
  bool disposed = false;

  void Function(String text, bool isFinal)? _onText;
  void Function(RecognizerProblem problem)? _onProblem;
  void Function()? _onDone;
  void Function()? _onListening;

  /// When true (default) the engine reports "listening" right after start.
  bool autoListening = true;

  @override
  Future<RecognizerInit> prepare(VoiceLanguage language) async {
    prepareCalls++;
    lastLanguage = language;
    final Completer<RecognizerInit>? gate = prepareGate;
    if (gate != null) return gate.future;
    return initResult;
  }

  @override
  Future<void> start({
    required String localeId,
    required void Function(String text, bool isFinal) onText,
    required void Function(RecognizerProblem problem) onProblem,
    required void Function() onDone,
    void Function()? onListening,
  }) async {
    startCalls++;
    listening = true;
    lastLocale = localeId;
    _onListening = onListening;
    if (autoListening) onListening?.call();
    _onText = onText;
    _onProblem = onProblem;
    _onDone = onDone;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (finishOnStop) finish();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    listening = false;
    _onText = null;
    _onProblem = null;
    _onDone = null;
  }

  @override
  void dispose() => disposed = true;

  // ---- test drivers
  void say(String text, {bool isFinal = false}) => _onText?.call(text, isFinal);

  /// Reports that the engine really opened the microphone.
  void engineListening() => _onListening?.call();

  void finish() {
    listening = false;
    _onDone?.call();
  }

  void fail(RecognizerProblem problem) {
    listening = false;
    _onProblem?.call(problem);
    _onDone?.call();
  }
}

/// Scriptable text-to-speech engine.
class FakeSynthesizer implements SpeechSynthesizerService {
  SynthesizerStatus status = SynthesizerStatus.ready;
  bool pauseSupported = true;
  bool pauseResult = true;

  /// When true, [speak] immediately reports that audio started.
  bool autoStart = false;

  final List<String> spoken = <String>[];
  final List<String> resumed = <String>[];
  int prepareCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  double? rate;
  double? volume;
  VoiceLanguage? lastLanguage;

  void Function() _start = () {};
  void Function() _complete = () {};
  void Function() _cancel = () {};
  void Function() _pause = () {};
  void Function() _continue = () {};
  void Function(String) _error = (String _) {};

  @override
  bool get supportsPause => pauseSupported;

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
    prepareCalls++;
    lastLanguage = language;
    return status;
  }

  @override
  Future<void> setRate(double value) async => rate = value;

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (autoStart) _start();
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<bool> pause() async {
    pauseCalls++;
    return pauseResult;
  }

  @override
  Future<void> resume(String text) async => resumed.add(text);

  @override
  void dispose() {}

  // ---- test drivers
  void startEvent() => _start();
  void completeEvent() => _complete();
  void cancelEvent() => _cancel();
  void pauseEvent() => _pause();
  void continueEvent() => _continue();
  void errorEvent(String message) => _error(message);
}
