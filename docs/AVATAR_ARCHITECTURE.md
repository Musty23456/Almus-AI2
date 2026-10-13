# ALMUS AI Phase 5: Avatar architecture and performance notes

## What was built
A 2.5D vector humanoid avatar, drawn entirely in code. No 3D engine, no
image/video/Lottie/Rive assets, no new packages, no paid services.

| Layer | File | Job |
|---|---|---|
| State | `models/robot_state.dart` | IDLE, LISTENING, THINKING, TALKING, HAPPY, ERROR |
| Targets | `avatar/avatar_targets.dart` | Resting look of each state (const data) |
| Animator | `avatar/avatar_animator.dart` | Pure Dart. Eases pose toward the target, adds blinking, glances, sway, breathing, talking mouth |
| Pose | `avatar/avatar_pose.dart` | Per-frame numbers (the renderer contract) |
| Painter | `avatar/avatar_painter.dart` | Draws a pose with Canvas |
| Widget | `widgets/robot_avatar.dart` | One Ticker, frame cap, reduce-motion, lifecycle |
| Profile | `avatar/avatar_profile.dart` + `assets/avatar/avatar_profile.json` | Optional local tuning file |
| Lab | `screens/avatar_lab_screen.dart` | Developer-only test screen |

Behaviours: natural random blinking (with occasional double blinks), eye
glances, scanning eyes while thinking, subtle head sway/tilt, breathing
(chest swell + bob), parallax (visor, eyes and mouth shift more than the shell
when the head turns, ear pods shift the opposite way), talking mouth with
phrase pauses, listening ripples, thinking dots, smiling-eye HAPPY, X-eye ERROR.
Every value eases with an exponential filter, so state changes never pop.

## Application state -> avatar state
Implemented in `ChatController` (`robotState`):

| App situation | Avatar |
|---|---|
| Waiting for input | IDLE |
| Typing in the chat box, or `setVoiceInputActive(true)` | LISTENING |
| AI request pending | THINKING (keeps priority over voice input) |
| Reply shown, or `setSpeechPlaybackActive(true)` | TALKING |
| After talking ends, or `celebrate()` (tap the Home avatar) | HAPPY ~1.5 s, then IDLE |
| Chat failure, or `reportFailure()` | ERROR ~3 s, then IDLE |

**Update (Phase 6):** the hooks below are now driven by the real voice
feature (see `docs/VOICE_ARCHITECTURE.md`). `setSpeechPlaybackActive` gained a
`natural` flag: true = brief HAPPY then IDLE, false (user stop, pause, failure)
= straight to IDLE. Original Phase 5 note follows.

**Important:** Phase 5 contained no microphone/speech-to-text and no
text-to-speech. `setVoiceInputActive` and `setSpeechPlaybackActive` are ready
hooks for those future features. Until then LISTENING follows typing, and
TALKING is simulated for a time based on reply length. When real speech
arrives, call `setSpeechPlaybackActive(true/false)` and TALKING lasts exactly
as long as the audio. `RobotAvatar(mouthLevel: ...)` accepts a real loudness
value (0..1) to drive the mouth.

## Fallbacks (nothing here can crash the app)
- Profile asset missing / unreadable / invalid JSON -> built-in defaults
  (`AvatarProfile.preload` never throws; values are clamped).
- The avatar does not need any asset to be drawn.
- If drawing throws in a release build, a plain fallback face is painted
  (debug builds rethrow so bugs are visible).
- System "reduce motion" -> still avatar, ticker stopped, state changes still shown.

## Performance design (by construction, not yet measured on a device)
- One `Ticker` per avatar; painter repaints only when the animator produced a frame.
- Frame cap: 30 fps default (profile `maxFps`), 24 fps for avatars under 80 px
  (chat header), 20 fps in low-power mode. Hidden tabs/routes stop ticking
  automatically (TickerMode).
- No shaders created per frame (three gradients created once), no blur
  filters, no `saveLayer`, one reused `Paint`. Glow is stacked translucent
  circles (5, or 3 in low power).
- `RepaintBoundary` isolates the avatar from the rest of the UI.
- No images and no new dependencies: APK size impact is a few KB of Dart code
  plus a ~200-byte JSON file. Memory is a handful of small objects.
- Please check on your phone: open **Settings -> tap Version 7 times -> Avatar Lab**.
  It shows painted frames per second and lets you enable low-power mode.
  For real GPU/RAM numbers use Flutter DevTools -> Performance (profile build).

## 3D: trade-offs and optional architecture
A real 3D humanoid is feasible but was **not** introduced because it would
likely add size and cost memory/GPU on low-RAM phones:
- A 3D engine/renderer package plus a rigged model with textures typically
  adds several MB to tens of MB to the APK and noticeably more GPU/RAM use
  (exact numbers depend on the engine and model: measure before deciding).
- Skinned-mesh rendering at 60 fps is much heavier than 2D vector drawing.
- Rigging, blendshapes and lip-sync assets must be sourced/licensed (free
  models exist but need checking).

Optional future path (nothing to rewrite):
1. Keep `AvatarAnimator` and `AvatarPose` as they are. They already express
   blink, gaze, head tilt/yaw/bob, breath, mouth open/smile and state colour.
2. Add `Avatar3DRenderer` (a widget with the same inputs as `RobotAvatar`)
   that maps pose -> bones/blendshapes of a small, low-poly glTF model (aim
   for under about 5k triangles and a single small texture).
3. Choose the renderer at runtime: 3D only on capable devices and when the
   user enables it; otherwise `RobotAvatar` (2D). If the model fails to load,
   fall back to `RobotAvatar`, the same pattern used for the profile asset.
4. Load the model lazily so the default install stays small.

## Files changed vs Phase 4
New: `lib/avatar/*`, `lib/screens/avatar_lab_screen.dart`,
`assets/avatar/avatar_profile.json`, new tests, this document.
Modified: `robot_state.dart` (+happy), `app_theme.dart` (amber for HAPPY),
`robot_avatar.dart` (rewritten, same `RobotAvatar(state:, size:)` call),
`chat_controller.dart`, `home_screen.dart` (tap avatar), `settings_screen.dart`
(hidden Developer tile), `main.dart` (preload profile), `pubspec.yaml`
(asset + 0.5.0), `app_info.dart`, README, and a few test timings.
