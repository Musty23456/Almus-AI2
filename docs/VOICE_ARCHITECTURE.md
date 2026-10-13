# ALMUS AI Phase 6: Voice architecture

## Layers
| Layer | File | Job |
|---|---|---|
| State machine | `voice/voice_state_machine.dart` | Pure: `(phase, event) -> phase`. Phases: idle, preparing, listening, speaking, paused |
| Controller | `voice/voice_controller.dart` | Side effects: permission, recognizer, TTS, timers, notices, avatar hooks |
| Recognizer | `voice/speech_recognizer.dart` | Interface + Android wrapper over `speech_to_text` |
| Synthesizer | `voice/speech_synthesizer.dart` | Interface + Android wrapper over `flutter_tts` |
| Text prep | `voice/speech_text.dart` | Removes code, links, markdown before speaking |
| Settings | `voice/voice_settings*.dart` | Auto speak, auto send, language, rate, volume (SharedPreferences) |

Voice is enabled only when `AlmusApp` receives both engines (`main.dart` passes the
Android ones). Without them the app behaves exactly like Phase 5, which keeps older
tests and platforms unaffected.

## Avatar mapping
| Situation | Avatar |
|---|---|
| Microphone open | LISTENING (`setVoiceInputActive`) |
| Waiting for the AI | THINKING (chat owns it; the mic is disabled meanwhile) |
| Audio actually playing | TALKING (`setSpeechPlaybackActive(true)`, on the engine's start event) |
| Playback ended naturally | HAPPY ~1.5 s, then IDLE (Phase 5 behaviour) |
| Stopped by user / paused / failed / mic cancelled | IDLE immediately |
| Unexpected recognizer failure | ERROR ~3 s, then IDLE |

## Lip sync limitation
Android TTS gives no phoneme or viseme data. The mouth uses the existing procedural
talking loop, active exactly while audio plays. It is synchronized to playback, not to
the words. `RobotAvatar(mouthLevel:)` can accept a real loudness value later.

## Privacy
- Permission is requested on the first microphone tap (inside `speech_to_text.initialize`).
- The mic opens only after a tap and closes on Done, Cancel, silence, error, new chat,
  leaving the Chat tab or backgrounding the app. There is no wake word or continuous listening.
- The app never records, stores or uploads audio; only text is returned. The system
  recognition service may send audio to Google (engine dependent).
- Errors and technical messages are shown, never spoken.

## Robustness
Stale callbacks are discarded with session counters; start and stop timeouts prevent
stuck states; cancel events caused by replacing or pausing playback are ignored;
every `(phase, event)` pair is covered by tests.
