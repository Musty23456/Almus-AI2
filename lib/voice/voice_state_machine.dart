/// Pure (no plugins, no I/O) state machine for voice interaction.
///
/// The [VoiceController] feeds it events coming from the user, the speech
/// recognizer and the speech synthesizer, and acts on the resulting phase.
/// Keeping it pure makes every transition unit-testable.
///
/// Phases:
/// - [VoicePhase.idle]        nothing is happening
/// - [VoicePhase.preparing]   mic tapped; permission / engine check running
/// - [VoicePhase.listening]   the microphone is open (user asked for it)
/// - [VoicePhase.speaking]    text-to-speech is playing (or about to)
/// - [VoicePhase.paused]      text-to-speech playback paused
///
/// "Thinking" (waiting for the AI) is owned by the chat, not by voice; the
/// controller simply refuses to start listening while the chat is busy.
enum VoicePhase { idle, preparing, listening, speaking, paused }

/// Everything that can happen to the voice interaction.
enum VoiceEvent {
  /// User tapped the microphone.
  micPressed,

  /// Permission was granted and the recognizer is ready.
  recognizerReady,

  /// Permission denied, or recognition unavailable / language unsupported.
  recognizerFailed,

  /// The recognizer delivered its final result (or the user tapped stop).
  recognitionFinished,

  /// The user cancelled listening (nothing is kept).
  listenCancelled,

  /// A recognition error / timeout happened while listening.
  listenError,

  /// Speech playback was requested (a reply arrived, or the user tapped play).
  speakRequested,

  /// The synthesizer reported that audio actually started.
  speechStarted,

  /// Playback finished naturally.
  speechCompleted,

  /// The user (or the app) stopped playback.
  speechStopped,

  /// The synthesizer reported an error.
  speechError,

  /// The user paused playback.
  pauseRequested,

  /// The user resumed playback.
  resumeRequested,

  /// The app lost audio focus / went to background / an interruption occurred.
  interrupted,
}

/// Result of applying an event: the new phase, or the same phase when the
/// event is not valid in the current phase.
class VoiceTransition {
  const VoiceTransition(this.phase, {required this.accepted});

  final VoicePhase phase;

  /// False when the event does not apply to the current phase (ignored).
  final bool accepted;
}

class VoiceStateMachine {
  const VoiceStateMachine();

  /// Returns what happens when [event] occurs in [from].
  ///
  /// Rules worth knowing:
  /// - the microphone and the speaker are never active together: pressing the
  ///   mic while speaking stops speech first (the controller does that), and a
  ///   speak request while listening is rejected so audio is not recorded;
  /// - every failure or interruption lands in [VoicePhase.idle], never in a
  ///   stuck state;
  /// - events that make no sense in a phase are ignored, not errors.
  VoiceTransition apply(VoicePhase from, VoiceEvent event) {
    VoiceTransition go(VoicePhase to) => VoiceTransition(to, accepted: true);
    VoiceTransition stay() => VoiceTransition(from, accepted: false);

    switch (event) {
      case VoiceEvent.micPressed:
        switch (from) {
          case VoicePhase.idle:
            return go(VoicePhase.preparing);
          case VoicePhase.speaking:
          case VoicePhase.paused:
            // Interrupt playback and start listening.
            return go(VoicePhase.preparing);
          case VoicePhase.preparing:
          case VoicePhase.listening:
            return stay();
        }
      case VoiceEvent.recognizerReady:
        return from == VoicePhase.preparing ? go(VoicePhase.listening) : stay();
      case VoiceEvent.recognizerFailed:
        return from == VoicePhase.preparing ? go(VoicePhase.idle) : stay();
      case VoiceEvent.recognitionFinished:
      case VoiceEvent.listenCancelled:
      case VoiceEvent.listenError:
        return from == VoicePhase.listening || from == VoicePhase.preparing
            ? go(VoicePhase.idle)
            : stay();
      case VoiceEvent.speakRequested:
        switch (from) {
          case VoicePhase.idle:
          case VoicePhase.speaking:
          case VoicePhase.paused:
            return go(VoicePhase.speaking);
          case VoicePhase.preparing:
          case VoicePhase.listening:
            return stay(); // never talk over an open microphone
        }
      case VoiceEvent.speechStarted:
        return from == VoicePhase.speaking ? go(VoicePhase.speaking) : stay();
      case VoiceEvent.speechCompleted:
      case VoiceEvent.speechStopped:
      case VoiceEvent.speechError:
        return from == VoicePhase.speaking || from == VoicePhase.paused
            ? go(VoicePhase.idle)
            : stay();
      case VoiceEvent.pauseRequested:
        return from == VoicePhase.speaking ? go(VoicePhase.paused) : stay();
      case VoiceEvent.resumeRequested:
        return from == VoicePhase.paused ? go(VoicePhase.speaking) : stay();
      case VoiceEvent.interrupted:
        return from == VoicePhase.idle ? stay() : go(VoicePhase.idle);
    }
  }
}
