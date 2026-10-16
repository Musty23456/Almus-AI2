import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'speech_recognizer.dart';
import 'speech_synthesizer.dart';
import 'speech_text.dart';
import 'voice_settings.dart';
import 'voice_settings_store.dart';
import 'voice_state_machine.dart';

/// What the voice feature needs from the chat so the avatar stays in sync.
/// [ChatController] implements it.
///
/// Avatar mapping: listening -> LISTENING (setVoiceInputActive), waiting for
/// the AI -> THINKING (owned by the chat), playback -> TALKING
/// (setSpeechPlaybackActive), everything finished -> IDLE.
abstract class VoiceAvatarHooks {
  /// True while an AI request is pending (the microphone is then disabled).
  bool get isBusy;

  void setVoiceInputActive(bool active);

  /// [natural] is true when playback ended on its own (a brief smile follows),
  /// false when the user stopped it or it failed (straight back to IDLE).
  void setSpeechPlaybackActive(bool active, {bool natural = true});

  void reportFailure();
}

/// Called with recognized text while listening ([isFinal] false) and once
/// when listening ends with a result ([isFinal] true).
typedef TranscriptListener = void Function(String text, bool isFinal);

/// Coordinates the microphone, speech recognition, text-to-speech and the
/// avatar. All decisions about which phase is legal live in
/// [VoiceStateMachine]; this class performs the side effects.
///
/// Privacy: the microphone opens only after the user taps it, never opens
/// again by itself, and closes on cancel, stop, silence, error, leaving the
/// chat or sending the app to the background. The app never records or stores
/// audio: Android's speech service listens and returns text only.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.recognizer,
    required this.synthesizer,
    required this.settings,
    required this.avatar,
    this.speechStartTimeout = const Duration(seconds: 8),
    this.stopTimeout = const Duration(seconds: 3),
  }) {
    synthesizer.onStart = _onSpeechStart;
    synthesizer.onComplete = _onSpeechComplete;
    synthesizer.onCancel = _onSpeechCancel;
    synthesizer.onPause = _onSpeechPause;
    synthesizer.onContinue = _onSpeechContinue;
    synthesizer.onError = _onSpeechError;
  }

  final SpeechRecognizerService recognizer;
  final SpeechSynthesizerService synthesizer;
  final VoiceSettingsController settings;
  final VoiceAvatarHooks avatar;

  /// How long to wait for the engine to report that audio started.
  final Duration speechStartTimeout;

  /// How long to wait for the recognizer to finish after the user taps stop.
  final Duration stopTimeout;

  /// Receives live and final recognized text (set by the chat screen).
  TranscriptListener? onTranscript;

  /// Called when the user cancels listening so the screen can drop the
  /// partial text it was showing.
  VoidCallback? onCancelled;

  static const VoiceStateMachine _machine = VoiceStateMachine();

  VoicePhase _phase = VoicePhase.idle;
  bool _disposed = false;
  int _listenSession = 0;
  int _speechSession = 0;
  bool _speechStarted = false;
  bool _pausing = false;
  bool _resuming = false;
  bool _synthUnavailable = false;
  final Set<VoiceLanguage> _warnedMissingVoice = <VoiceLanguage>{};
  Timer? _startTimer;
  Timer? _stopTimer;
  String _lastText = '';
  bool _micOpen = false;
  bool _processing = false;
  String? _heard;
  String _currentText = '';
  String? _speakingId;
  String? _notice;
  bool _noticeIsError = false;

  VoicePhase get phase => _phase;
  bool get isPreparing => _phase == VoicePhase.preparing;
  bool get isListening => _phase == VoicePhase.listening;
  bool get isSpeaking => _phase == VoicePhase.speaking;
  bool get isPaused => _phase == VoicePhase.paused;

  /// True while the microphone is requested or open.
  bool get micActive => isPreparing || isListening;

  /// Text recognized so far in the current listening session.
  String get transcript => _lastText;

  /// True once the engine really opened the microphone (before that the bar
  /// says "starting", so nobody speaks into a closed microphone).
  bool get micOpen => _micOpen;

  /// True after the user pressed stop, while the engine finishes.
  bool get isProcessing => _processing;

  /// The words recognized by the last session that ended with text. The
  /// chat shows them for checking before anything is sent.
  String? get heardPreview => _heard;

  void clearHeardPreview() {
    if (_heard == null) return;
    _heard = null;
    _notify();
  }

  /// Id of the message being read aloud (null for sample text or when quiet).
  String? get speakingMessageId => _speakingId;

  bool get canPause => synthesizer.supportsPause;

  /// False once the phone is known to have no text-to-speech engine.
  bool get speechAvailable => !_synthUnavailable;

  /// A user-facing explanation (never spoken aloud), or null.
  String? get notice => _notice;
  bool get noticeIsError => _noticeIsError;

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  // ----------------------------------------------------------- listening

  /// Starts voice input. Permission is requested here, on first use only.
  Future<void> startListening() async {
    if (_disposed) return;
    if (avatar.isBusy) {
      _setNotice(
        'Almus is still answering. Wait a moment, then tap the microphone.',
      );
      return;
    }
    final VoicePhase before = _phase;
    if (!_apply(VoiceEvent.micPressed)) return;
    final int session = ++_listenSession;
    _notice = null;
    _lastText = '';
    _heard = null;
    _micOpen = false;
    _processing = false;
    if (before == VoicePhase.speaking || before == VoicePhase.paused) {
      _endSpeechSilently();
      await synthesizer.stop();
    }
    _notify();
    if (!_listenCurrent(session, VoicePhase.preparing)) return;

    final VoiceLanguage language = settings.value.language;
    final RecognizerInit init = await recognizer.prepare(language);
    if (!_listenCurrent(session, VoicePhase.preparing)) return;
    if (!init.ok) {
      _apply(VoiceEvent.recognizerFailed);
      _setNotice(
        problemMessage(init.problem ?? RecognizerProblem.other, language),
        isError: true,
      );
      return;
    }
    _apply(VoiceEvent.recognizerReady);
    avatar.setVoiceInputActive(true);
    _notify();
    await recognizer.start(
      localeId: init.localeId ?? '',
      onText: (String text, bool isFinal) => _onText(session, text),
      onProblem: (RecognizerProblem p) => _onProblem(session, p),
      onDone: () => _onDone(session),
      onListening: () => _onEngineListening(session),
    );
  }

  /// Stops this session (silently) and starts a new one: the Retry button.
  Future<void> retryListening() async {
    cancelListening(quiet: true);
    await startListening();
  }

  void _onEngineListening(int session) {
    if (!_listenCurrent(session, VoicePhase.listening)) return;
    _micOpen = true;
    _notify();
  }

  /// Stops listening and keeps what was heard (the "done" action).
  Future<void> stopListening() async {
    if (_phase == VoicePhase.preparing) {
      cancelListening();
      return;
    }
    if (_phase != VoicePhase.listening) return;
    final int session = _listenSession;
    _processing = true;
    _notify();
    _stopTimer?.cancel();
    _stopTimer = Timer(stopTimeout, () => _onDone(session));
    await recognizer.stop();
  }

  /// Stops listening and throws away what was heard. When [quiet] is true the
  /// screen is not told (used when a typed message is being sent).
  void cancelListening({bool quiet = false}) {
    if (_phase != VoicePhase.listening && _phase != VoicePhase.preparing) {
      return;
    }
    final bool wasListening = _phase == VoicePhase.listening;
    _listenSession++;
    _stopTimer?.cancel();
    _apply(VoiceEvent.listenCancelled);
    if (wasListening) avatar.setVoiceInputActive(false);
    _lastText = '';
    _micOpen = false;
    _processing = false;
    unawaited(recognizer.cancel());
    if (!quiet) onCancelled?.call();
    _notify();
  }

  void _onText(int session, String text) {
    if (!_listenCurrent(session, VoicePhase.listening)) return;
    _lastText = text;
    onTranscript?.call(text, false);
    _notify();
  }

  void _onProblem(int session, RecognizerProblem problem) {
    if (!_listenCurrent(session, VoicePhase.listening)) return;
    final String heard = _lastText.trim();
    _finishListening(VoiceEvent.listenError);
    if (problem == RecognizerProblem.noSpeech && heard.isNotEmpty) {
      _deliver(heard);
      return;
    }
    _setNotice(
      problemMessage(problem, settings.value.language),
      isError: problem != RecognizerProblem.noSpeech,
    );
    if (problem == RecognizerProblem.other) avatar.reportFailure();
  }

  void _onDone(int session) {
    if (!_listenCurrent(session, VoicePhase.listening)) return;
    final String heard = _lastText.trim();
    _finishListening(VoiceEvent.recognitionFinished);
    if (heard.isNotEmpty) {
      _deliver(heard);
    } else {
      _setNotice(problemMessage(
        RecognizerProblem.noSpeech,
        settings.value.language,
      ));
    }
  }

  void _deliver(String heard) {
    _heard = heard;
    onTranscript?.call(heard, true);
    _notify();
  }

  void _finishListening(VoiceEvent event) {
    _micOpen = false;
    _processing = false;
    _stopTimer?.cancel();
    _apply(event);
    avatar.setVoiceInputActive(false);
    _notify();
  }

  bool _listenCurrent(int session, VoicePhase phase) =>
      !_disposed && session == _listenSession && _phase == phase;

  /// A friendly explanation for each recognizer problem. Never blames the
  /// user and always offers typing as the fallback.
  static String problemMessage(RecognizerProblem p, VoiceLanguage language) {
    switch (p) {
      case RecognizerProblem.permissionDenied:
        return 'Microphone permission was not granted, so voice input is off. You can still type. To use voice, allow Microphone for ALMUS AI in Android Settings > Apps > ALMUS AI > Permissions.';
      case RecognizerProblem.unavailable:
        return 'Speech recognition is not available on this phone. Install or enable Speech Services by Google (or another voice-typing app), or type your message.';
      case RecognizerProblem.languageUnsupported:
        return language == VoiceLanguage.hausa
            ? 'Hausa speech recognition is not installed on this phone. Not every phone supports Hausa. Switch to English in Settings, add Hausa in your phone\'s voice-typing languages, or type instead.'
            : 'English speech recognition is not installed on this phone. Check your phone\'s voice-typing languages, or type instead.';
      case RecognizerProblem.noSpeech:
        return 'I did not hear anything. Tap the microphone and try again.';
      case RecognizerProblem.busy:
        return 'The speech recognizer is busy. Close other apps that use the microphone and try again.';
      case RecognizerProblem.network:
        return 'Speech recognition could not reach the internet. Check your connection and try again, or type instead.';
      case RecognizerProblem.notStarted:
        return 'The phone\'s speech service did not start listening. Make sure Speech Services by Google (or another voice-typing app) is installed and enabled, then try again, or type your message.';
      case RecognizerProblem.other:
        return 'Voice input stopped unexpectedly. Please try again or type your message.';
    }
  }

  // ------------------------------------------------------------ speaking

  /// Hook for [ChatController.onAssistantReply]: reads a fresh reply aloud
  /// when automatic speech is on. Error messages are never read.
  void handleReply(ChatMessage message) {
    if (_disposed || !settings.value.autoSpeak) return;
    if (message.isError || message.sender != MessageSender.assistant) return;
    if (_synthUnavailable || micActive) return;
    unawaited(speakMessage(message, automatic: true));
  }

  /// Reads one assistant message aloud (the speaker button on a bubble).
  Future<void> speakMessage(ChatMessage message, {bool automatic = false}) {
    if (message.sender != MessageSender.assistant || message.isError) {
      return Future<void>.value();
    }
    return speakText(message.text, id: message.id, automatic: automatic);
  }

  /// Reads [raw] aloud after removing markdown, links and code.
  Future<void> speakText(
    String raw, {
    String? id,
    bool automatic = false,
  }) async {
    if (_disposed) return;
    final String text = SpeechText.clean(raw);
    if (text.isEmpty) {
      if (!automatic) _setNotice('There is nothing to read aloud here.');
      return;
    }
    if (micActive) {
      if (!automatic) {
        _setNotice('Stop listening first, then Almus can read aloud.');
      }
      return;
    }
    if (_synthUnavailable) {
      if (!automatic) _setNotice(_noEngineMessage, isError: true);
      return;
    }
    final bool replacing = _phase == VoicePhase.speaking ||
        _phase == VoicePhase.paused;
    if (!_apply(VoiceEvent.speakRequested)) return;
    final int session = ++_speechSession;
    _speakingId = id;
    _currentText = text;
    _speechStarted = false;
    _pausing = false;
    _resuming = false;
    _startTimer?.cancel();
    _notify();

    if (replacing) {
      await synthesizer.stop();
      if (!_speechCurrent(session)) return;
    }
    final SynthesizerStatus status =
        await synthesizer.prepare(settings.value.language);
    if (!_speechCurrent(session)) return;
    if (status == SynthesizerStatus.unavailable) {
      _synthUnavailable = true;
      _failSpeech(_noEngineMessage);
      return;
    }
    final VoiceLanguage language = settings.value.language;
    if (status == SynthesizerStatus.languageMissing &&
        _warnedMissingVoice.add(language)) {
      _setNotice(
        'No ${language.label} voice is installed on this phone, so Almus uses your phone\'s default voice. Pronunciation may be poor. You can turn off automatic speech in Settings.',
      );
    }
    await synthesizer.setRate(settings.value.speechRate);
    await synthesizer.setVolume(settings.value.volume);
    if (!_speechCurrent(session)) return;
    _armStartTimer(session);
    await synthesizer.speak(text);
  }

  /// Stops playback (user action). Goes straight back to IDLE.
  Future<void> stopSpeaking() async {
    if (_phase != VoicePhase.speaking && _phase != VoicePhase.paused) return;
    _speechSession++;
    _endPlayback(VoiceEvent.speechStopped, natural: false);
    await synthesizer.stop();
  }

  /// Pauses playback when the speech engine supports it. If pausing fails,
  /// playback is stopped instead and the user is told why.
  Future<void> pauseSpeaking() async {
    if (_phase != VoicePhase.speaking || !_speechStarted) return;
    if (!synthesizer.supportsPause) {
      _setNotice('This phone\'s speech engine cannot pause. Use Stop instead.');
      return;
    }
    final int session = _speechSession;
    _pausing = true;
    final bool ok = await synthesizer.pause();
    _pausing = false;
    if (!_speechCurrent(session)) return;
    if (ok) {
      _apply(VoiceEvent.pauseRequested);
      _startTimer?.cancel();
      avatar.setSpeechPlaybackActive(false, natural: false);
      _notify();
    } else {
      _setNotice(
        'Pausing is not supported by this speech engine, so playback was stopped.',
      );
      await stopSpeaking();
    }
  }

  Future<void> resumeSpeaking() async {
    if (_phase != VoicePhase.paused) return;
    final int session = _speechSession;
    _resuming = true;
    _apply(VoiceEvent.resumeRequested);
    _speechStarted = false;
    _armStartTimer(session);
    _notify();
    await synthesizer.resume(_currentText);
    _resuming = false;
  }

  /// Interrupts everything (app sent to background, conversation changed).
  /// While the permission dialog is showing ([includePreparing] false) the
  /// pending microphone request is left alone.
  void interrupt({bool includePreparing = false}) {
    if (_disposed) return;
    if (_phase == VoicePhase.listening ||
        (includePreparing && _phase == VoicePhase.preparing)) {
      cancelListening();
    } else if (_phase == VoicePhase.speaking || _phase == VoicePhase.paused) {
      unawaited(stopSpeaking());
    }
  }

  /// Stops listening and speaking right now (new chat, delete chat, ...).
  void stopAll() => interrupt(includePreparing: true);

  void _armStartTimer(int session) {
    _startTimer?.cancel();
    _startTimer = Timer(speechStartTimeout, () {
      if (_speechCurrent(session) && !_speechStarted) {
        _failSpeech(
          'Speech did not start. Check that a text-to-speech engine is installed and your media volume is up.',
        );
      }
    });
  }

  bool _speechCurrent(int session) =>
      !_disposed && session == _speechSession && _phase == VoicePhase.speaking;

  static const String _noEngineMessage =
      'Text-to-speech is not available on this phone. Install Speech Services by Google (or another text-to-speech engine) to hear replies.';

  void _onSpeechStart() {
    if (_disposed || _phase != VoicePhase.speaking) return;
    _speechStarted = true;
    _resuming = false;
    _startTimer?.cancel();
    avatar.setSpeechPlaybackActive(true);
    _notify();
  }

  void _onSpeechComplete() {
    if (_disposed) return;
    if (_phase != VoicePhase.speaking && _phase != VoicePhase.paused) return;
    _speechSession++;
    _endPlayback(VoiceEvent.speechCompleted, natural: true);
  }

  void _onSpeechCancel() {
    // Ignore cancels that belong to a previous utterance or to a pause.
    if (_disposed || !_speechStarted || _pausing || _resuming) return;
    if (_phase != VoicePhase.speaking) return;
    _speechSession++;
    _endPlayback(VoiceEvent.speechStopped, natural: false);
  }

  void _onSpeechPause() {
    if (_disposed || _pausing || _phase != VoicePhase.speaking) return;
    // The engine paused by itself (for example another app took audio focus).
    _apply(VoiceEvent.pauseRequested);
    avatar.setSpeechPlaybackActive(false, natural: false);
    _notify();
  }

  void _onSpeechContinue() {
    if (_disposed || _resuming || _phase != VoicePhase.paused) return;
    _apply(VoiceEvent.resumeRequested);
    avatar.setSpeechPlaybackActive(true);
    _notify();
  }

  void _onSpeechError(String message) {
    if (_disposed) return;
    if (_phase != VoicePhase.speaking && _phase != VoicePhase.paused) return;
    // The raw engine message is technical, so it is not shown or spoken.
    _failSpeech('Text-to-speech stopped because of a problem on the phone.');
  }

  void _failSpeech(String message) {
    _speechSession++;
    _startTimer?.cancel();
    _endPlayback(VoiceEvent.speechError, natural: false, notify: false);
    _setNotice(message, isError: true);
    unawaited(synthesizer.stop());
  }

  void _endPlayback(
    VoiceEvent event, {
    required bool natural,
    bool notify = true,
  }) {
    _startTimer?.cancel();
    _apply(event);
    _clearSpeechState();
    avatar.setSpeechPlaybackActive(false, natural: natural);
    if (notify) _notify();
  }

  /// Drops playback bookkeeping without touching the phase (the caller has
  /// already moved the phase, e.g. the microphone was pressed).
  void _endSpeechSilently() {
    _speechSession++;
    _startTimer?.cancel();
    _clearSpeechState();
    avatar.setSpeechPlaybackActive(false, natural: false);
  }

  void _clearSpeechState() {
    _speechStarted = false;
    _pausing = false;
    _resuming = false;
    _speakingId = null;
    _currentText = '';
  }

  // -------------------------------------------------------------- shared

  bool _apply(VoiceEvent event) {
    final VoiceTransition t = _machine.apply(_phase, event);
    if (t.accepted) _phase = t.phase;
    return t.accepted;
  }

  void _setNotice(String text, {bool isError = false}) {
    _notice = text;
    _noticeIsError = isError;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _startTimer?.cancel();
    _stopTimer?.cancel();
    synthesizer.onStart = () {};
    synthesizer.onComplete = () {};
    synthesizer.onCancel = () {};
    synthesizer.onPause = () {};
    synthesizer.onContinue = () {};
    synthesizer.onError = (String _) {};
    onTranscript = null;
    onCancelled = null;
    unawaited(recognizer.cancel());
    unawaited(synthesizer.stop());
    super.dispose();
  }
}
