# ALMUS AI Personal Assistant — Phase 9

> **Phase 4 (multi-provider AI) is the latest work:** the backend can use Gemini, Groq, OpenRouter or any OpenAI-compatible
> service, with health tracking, bounded retries and opt-in fallback. See `PHASE_4_REPORT.md` and `docs/PROVIDERS.md`.
> The Flutter code from Phases 1-4 has still never been compiled or run (no Flutter SDK was available).

> **Phase 1 stabilization (audit) is documented in `PHASE_1_REPORT.md`.** See also `CHANGELOG.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN_LIMITATIONS.md` and `docs/BUILD_AND_TEST.md`. The `android/` folder is generated: run `bash tool/bootstrap_android.sh` before a local Android build.

A personal AI assistant for Android, built with Flutter (Material 3).

**Phase 2** adds real Gemini conversations through a backend that you deploy yourself (see the separate `almus-backend` project). The app never contains your Gemini API key. In **Settings → Gemini connection** you enter your backend URL and an access token. With no backend URL the app stays in clearly labelled **DEMO MODE** (scripted replies).

**Phase 3** saves your conversations in a local SQLite database on the phone, so chats are restored after the app closes and reopens. The **History** tab lists, searches, renames and deletes saved conversations. Saved history is *not* AI memory: Almus does not learn from or recall old chats; when you continue a chat only its most recent messages are sent as context.

**Phase 4** adds a user-controlled **personal memory**. Almus can recall facts you approved (profile, preferences, learning progress, projects, goals, approved facts, chat summaries) and continue ongoing work without you explaining everything again. Memory is local, optional and visible: you can view, add, edit, delete, confirm, reject, disable and clear it.

**Phase 5** upgrades the robot into an expressive 2.5D humanoid avatar with six states (Idle, Listening, Thinking, Talking, Happy, Error): natural blinking, eye movement, head sway, breathing, smooth transitions and a talking mouth. It is drawn in code (no 3D engine, no big assets, no new packages), capped at 30 fps, and falls back safely if the optional tuning asset is missing. Tap the Home avatar to make it smile. Developer-only **Avatar Lab**: Settings, tap *Version* 7 times, open *Avatar Lab*. See `docs/AVATAR_ARCHITECTURE.md` for architecture, performance notes and the optional 3D plan. 

**Phase 6** adds voice. Tap the **microphone** in Chat to dictate (English or Hausa), and Almus **reads replies aloud** with Android text-to-speech. See the Phase 6 section below and `docs/VOICE_ARCHITECTURE.md`.

**Phase 7** adds a **biometric app lock**. When you open ALMUS AI a futuristic lock screen appears (animated eye, scanning rings and beam) and Android's own fingerprint / face prompt opens. The app unlocks only when **Android** says the identity is confirmed. See the Phase 7 section below and `docs/SECURITY_ARCHITECTURE.md`.

## Phase 9: On-device face detection and enrollment prototype

Phase 9 adds a Settings screen that captures a face sample using the front camera, runs Google ML Kit face detection locally, and saves the photo in the app-private support directory only when exactly one face is detected. The user can replace or delete the sample. No image is uploaded to the Almus backend or Gemini.

**Security limit:** face detection is not face identity recognition. This phase does not create face embeddings, compare identities, perform liveness/anti-spoofing, or unlock the app. The app lock continues to trust only Android's native biometric prompt. Do not use this sample as proof of identity. A later recognition phase needs a reviewed on-device face-embedding model, similarity thresholds, liveness protections and security tests before it can be considered for authentication. See `docs/PHASE_9_FACE_DETECTION.md`.

## Phase 8: Native face authentication

Phase 8 improves the lock UI to report when Android lists an enrolled face biometric and uses a face-themed icon where appropriate. Identity verification remains delegated to Android\'s native biometric prompt; the app does not capture face images or run a custom face-matching model. The generic Android prompt may accept any biometric permitted by the OS, so face-only authentication cannot be guaranteed on every phone. See `docs/PHASE_8_FACE_AUTHENTICATION.md`.

## Phase 7: Biometric security

**What it does**
- Lock screen ("ALMUS AI SECURITY") with the animated eye, shown before any private screen. Chat, History, Memory and Settings are not even built until the first unlock, are hidden and untouchable while locked, and the lock screen also covers dialogs.
- States: LOCKED, INITIALIZING, SCANNING, AUTHENTICATING, VERIFIED ("IDENTITY VERIFIED"), FAILED ("AUTHENTICATION FAILED"), CANCELLED, UNAVAILABLE, LOCKOUT. The first two animation phases are short and fixed (about 0.8 s together); AUTHENTICATING lasts exactly as long as Android's prompt. There is no fake endless scan.
- Auto-lock: Immediately (default), after 15 seconds, 1 minute or 5 minutes in the background. A longer delay asks you to confirm first.
- Settings > Security: turn the lock on/off, see available methods, "Test biometric availability", auto-lock, allow device PIN/pattern/password. Turning the lock off, lengthening auto-lock and allowing the PIN each need Android to confirm you first.
- While the lock is on, screenshots and the recent-apps preview are blocked (Android FLAG_SECURE). Spoken replies are not read aloud while locked.
- Not included on purpose: no app-managed PIN (so no PIN storage, hashing or attempt counter to get wrong; the phone's own screen lock does that job through Android), no camera access, no sound files (the success/failure feedback is a short vibration).

**Which methods actually work (honest summary)**
- Fingerprint and face: whatever your phone's Android reports as a supported biometric and you enrolled. The app cannot tell you whether it is a face, a finger or an iris: modern Android only reports *strong* or *weak* classes.
- Device PIN / pattern / password: through Android's prompt (offered as the fallback button and used directly when no biometric is enrolled).
- **Iris recognition is not implemented and the app never claims it.** The eye graphic is decoration and can never grant access.
- Face unlock quality differs between phones. Many are "weak" (Class 2) and some can be fooled by a photo. The `local_auth` plugin decides which classes its prompt accepts; I could not verify that from here, so treat face unlock as less secure than fingerprint unless your phone documents it as Class 3 (strong). For the best protection use a fingerprint or PIN.
- The plugin reports "not confirmed" the same way whether the user pressed Cancel or the biometric did not match, so on a real phone both appear as AUTHENTICATION FAILED. (The CANCELLED state exists and is used when Android reports an explicit cancel.)

**Turn it on / try it on a phone**
1. Install the APK from the GitHub Actions artifact.
2. In Android Settings > Security (or Biometrics) set a screen lock and add a fingerprint or face.
3. Open ALMUS AI: the lock screen appears and Android's prompt opens. Unlock. Try: wrong finger (stays locked), Cancel (stays locked), press Home and return (locks immediately by default), change auto-lock in Settings > Security, "Test biometric availability".
4. Without any screen lock the app explains that it cannot be protected and offers "Continue without lock".

**Privacy and security**
- No biometric data (images, templates, scores) ever reaches the app. Nothing biometric is sent to Gemini or the backend. No camera permission is requested.
- The lock **hides** the app. It does **not** encrypt the SQLite chat/memory database: someone with a rooted phone or a backup could still read that file. Database encryption (for example SQLCipher with a key kept in the Android Keystore) is a separate future step.
- No notifications are used, so there are no notification previews to protect.

**Build notes.** New package: `local_auth`. `tool/patch_android_biometric.py` (run by the workflow after `flutter create`) adds the `USE_BIOMETRIC` permission, makes `MainActivity` a `FlutterFragmentActivity` (required by local_auth), adds the small FLAG_SECURE channel and switches the app themes to an AppCompat parent. For local builds run it once after `flutter create`. If the generated Android files look different from what it expects it stops with an error instead of building a lock that does not work.

**Testing status.** Automated tests use a fake biometric service (states, success, failure, cancel, unavailable, lockout, auto-lock, stale answers, lifecycle, fallback, settings confirmation, gate and screens). **No test used real biometrics and the app has not been run on a physical phone**; the real prompt, the FLAG_SECURE behaviour and the Android patch must be checked on a device.


## Phase 6: Voice input and spoken replies
**Voice input.** Mic button next to Send. First tap triggers Android's microphone permission dialog (never earlier). A red *Listening* bar shows the live text with **Cancel** (discard) and **Done** (keep). Recognized text goes into the message box so you can check it; turn on *Send voice messages automatically* in Settings to skip that. The mic is disabled while Almus is thinking.

**Voice output.** Each new reply is read aloud (switch off with the speaker icon in the Chat header or in Settings). A speaker button under every Almus reply reads or stops it. A bar offers **Pause/Resume** (only if the engine supports it; if pausing fails, playback stops and you are told) and **Stop**. Settings: speech speed, volume, language, *Test voice*. Error messages, links, code and markdown symbols are never read.

**Languages.** English and Hausa, chosen in Settings. Support depends on the phone's Google Speech Services: Hausa recognition and a Hausa voice are not available on every device. If missing, Almus says so (no silent fallback to English for listening; for speaking it uses the default voice and warns once). Not tested on real devices.

**Avatar.** LISTENING while the mic is open, THINKING while waiting, TALKING while audio plays, then IDLE.

**Limitations.** No phoneme lip-sync: the mouth plays a generic talking loop while audio is active. Android pause/resume depends on the TTS plugin and engine and may restart the text. Phone calls or other apps taking audio may cut playback or listening; the app returns to IDLE. Recognition engines may send audio to Google and may need internet.

**Privacy.** No continuous or background listening, no wake word. Audio is never recorded or stored by the app. Listening and speech stop when you leave Chat, start a new chat, or background the app.

**Build notes.** New packages: `speech_to_text`, `flutter_tts`. `tool/patch_android_manifest.py` (run by the workflow after `flutter create`) adds `RECORD_AUDIO` and the `<queries>` entries Android 11+ needs for speech services. For local builds run it once after `flutter create`.

## Phase 4: Personal memory
**Tabs:** Home, Chat, **History** (the saved chats from Phase 3), **Memory** (new), Settings.

**Memory record:** unique ID, category, text, created date, last-updated date, source conversation (when known) and a confirmed/suggested status. Categories: Personal profile, Preferences, Learning progress, Projects, Goals and plans, Approved facts, Conversation summaries.

**Managing memory (Memory tab):** add a memory, edit, delete (with confirmation), save or dismiss suggestions, the **Use memory** switch, and **Clear all memories**. In Chat a small bar shows whether memory is on, lets you **turn memory off for just that chat** (the choice is saved with the chat), lists which memories were used in the last reply, and shows a "Remember this?" suggestion. In History, a chat's menu has **Save summary to memory**.

**How memories are created**
- You add them yourself. Nothing is saved without you.
- Almus *suggests* a memory when you write things like "remember that…", "my name is…", "I am learning…", "I am building…" or "my goal is…" (a few Hausa phrases too). This uses simple pattern matching on the phone, no AI and no network. A suggestion is **never used until you tap Save**.
- Summaries are drafted from your own messages without AI, shown to you in an editable box, and saved only when you tap Save.

**Sensitive information:** passwords, PINs, API keys, card and ID/account numbers are never stored, not even if you insist. Text about health, religion, politics, sexuality, money, legal/immigration matters, your home address or ethnicity is never suggested; if you add it yourself you must confirm a warning first. The check uses simple word patterns, so it is a safety net, not a guarantee: do not put secrets into memory.

**Retrieval (before each live request):** the app scores your *confirmed* memories against your message with local keyword matching (BM25-style weighting, light stemming, English and basic Hausa stop words). Short follow-ups reuse the previous message's topic, and words like "continue" or "resume" bring back your most recent projects, goals and learning items. At most 5 memories (at most 2 summaries) and 1,800 characters are sent; weak matches are dropped. The whole memory or chat database is never sent. Confirmed facts and approximate summaries are labelled separately, and the AI is told that anything not listed is not remembered.

**Privacy**
- The memory database is local (same SQLite file as history, new tables `memories`, `memory_prefs`, `memory_conversation_flags`).
- In LIVE MODE the memories that matched your message are sent with it to your backend and on to Google Gemini. In DEMO MODE nothing is retrieved or sent.
- Nothing is retrieved or suggested when memory is switched off (globally or for that chat).
- The backend does not log or store memory text.

**Backend change (required for memory to reach Gemini):** `POST /v1/chat` accepts an optional `memoryContext` string (max `MAX_MEMORY_CHARS`, default 3000) that is appended to the system instruction. Redeploy the updated `Backend/` folder. An old backend ignores the field, so chat still works but Gemini never sees your memories.

## Features
- Polished splash screen and dark futuristic theme (blue / cyan / purple), optional light theme
- Animated humanoid robot avatar drawn in code (no assets needed) with states: idle, listening, thinking, talking, error
- Home, Chat, Memory and Settings sections with bottom navigation
- Chat UI: bubbles, timestamps, send, clear chat, empty/typing/error states, DEMO MODE or LIVE MODE banner
- Real Gemini replies via your backend with conversation context (last 20 messages / 12,000 characters), robot THINKING while waiting then TALKING/IDLE, and no duplicate submissions
- Friendly messages for no internet, timeouts, rate limits / quota, wrong token, and backend errors
- Settings: backend URL + access token (stored in app-private storage), Test connection button
- Local chat history (SQLite): conversations and messages with timestamps, saved after each message, restored on restart (the most recent chat reopens automatically)
- History tab: conversation list (newest first), search by title or message text, open, rename, delete (with confirmation), and Clear all history (with confirmation)
- Chat: New chat button; Clear chat deletes the open conversation; a clear notice if saving fails (chatting keeps working)
- Settings: theme preference, app info, about, privacy, version
- Phase 4 personal memory (see above)
- Tests for the database, migrations, persistence, controller, memory and UI, plus a GitHub Actions workflow that analyzes, tests and builds a release APK

## Project structure
```
lib/
  main.dart, app.dart
  models/        chat_message.dart, conversation.dart, robot_state.dart, app_settings.dart,
                 memory_item.dart
  data/          app_database.dart (schema + migrations), conversation_repository.dart (interface),
                 sqlite_conversation_repository.dart, memory_conversation_repository.dart,
                 repository_factory.dart, storage_exception.dart,
                 memory_repository.dart (interface), sqlite_memory_repository.dart,
                 volatile_memory_repository.dart
  controllers/   chat_controller.dart, history_controller.dart, settings_controller.dart,
                 memory_controller.dart
  services/      chat_service.dart, demo_chat_service.dart, backend_client.dart,
                 routed_chat_service.dart, settings_store.dart,
                 memory_text.dart, sensitive_filter.dart, memory_extractor.dart,
                 memory_retrieval.dart (retrieval + context builder)
  screens/       splash, app_shell, home, chat, history, memory, settings
  widgets/       robot_avatar.dart + shared UI widgets
  theme/         app_theme.dart
  utils/         formatters.dart, app_info.dart, ids.dart
  voice/         voice_state_machine.dart, voice_controller.dart, speech_recognizer.dart,
                 speech_synthesizer.dart, speech_text.dart, voice_settings.dart, voice_settings_store.dart
tool/            patch_android_manifest.py
test/            widget, controller, backend-client and database tests
Backend/         the Gemini backend (deployed separately on Render)
assets/          images/, animations/ (optional, unused so far)
.github/workflows/main.yml
```
The `android/` folder is generated automatically by the workflow (`flutter create`) using the Flutter version it installs, so Gradle/Kotlin versions always match.

## Build the APK with GitHub Actions
1. Push to `main`, or open **Actions → Build Android APK → Run workflow**. The workflow installs the SQLite library on the CI machine so the database tests can run.
2. When the run is green, open it and download the **almus-ai-release-apk** artifact (a ZIP containing `app-release.apk`).
3. Extract it on your phone and open the APK. Allow "Install unknown apps" for your browser/Files app if Android asks.

The APK is signed with the debug key, which is fine for personal use. Do not publish it to the Play Store as is.

## Run locally (optional)
```
flutter create --platforms=android --org com.almus --project-name almus_ai .
python3 tool/patch_android_manifest.py
flutter pub get
flutter analyze
flutter test
flutter run
```

## Local database
- File `almus_ai.db` in the app's private storage (Android SQLite via `sqflite`). Nothing leaves the phone from this database.
- Tables: `conversations (id, title, created_at, updated_at)` and `messages (id, conversation_id, role, content, created_at, status, engine)`. `role` is `user` or `assistant` (enforced by a CHECK constraint), `status` is `sent` or `error`, and deleting a conversation cascades to its messages. Timestamps are epoch milliseconds.
- Phase 4 (migration 2) adds `memories (id, category, text, created_at, updated_at, source_conversation_id, status)`, `memory_prefs (name, value)` and `memory_conversation_flags (conversation_id)`. Memories have no foreign key to chats, so deleting a chat does not delete memories you saved from it.
- Schema changes go through `kMigrations` in `lib/data/app_database.dart`: add a new `Migration` with a higher version; never edit an old one. Existing data is kept on upgrade.
- No credentials are stored here. The backend URL and access token live in separate app-private preferences (see Phase 2).
- The UI talks only to the `ConversationRepository` interface. If the database cannot be opened, the app falls back to in-memory history and shows a notice.
- Search is a case-insensitive text match (SQLite `LIKE`, ASCII case folding) over titles and message text.

## Connecting to Gemini
1. Deploy the backend (`almus-backend`, see its README) and set `GEMINI_API_KEY` and `APP_ACCESS_TOKEN` in the hosting dashboard.
2. In the app open **Settings → Gemini connection**, enter the https backend URL and the same access token, tap **Test connection**, then **Save**.
3. Chat switches to LIVE MODE. Clear the URL to return to DEMO MODE.

The model is chosen on the backend (`GEMINI_MODEL`), so changing it never needs a new APK. The release APK includes the INTERNET permission (added by the workflow).

## Other AI providers (Phase 4)
Gemini stays the default. To add Groq, OpenRouter or another OpenAI-compatible service, set its key and model on the
**backend** (never in the app), then open **Settings → AI providers** to check connections, pick a model and decide
whether automatic fallback may be used (off by default). Guide: `docs/PROVIDERS.md`.

## Known limitations
- Replies are not streamed; they appear when complete. Voice (Phase 6) has the limits listed in its section; it has not been run on a physical phone yet.
- Memory retrieval is keyword based, not semantic: a memory is found only if it shares words with your message (basic stemming, no synonyms). Suggestions and the sensitive-text check use simple patterns and miss many cases.
- Memory and chat history are stored unencrypted in app-private storage and are not synced or backed up.
- Memory summaries are extractive (built from your messages), not written by AI.
- The theme choice is not saved when the app closes (the backend URL, token and chat history are).
- If a database write fails, that message stays on screen but is not retried; the app shows a notice.
- Chat history is stored unencrypted in app-private storage and is not backed up or synced between devices.
- Search matches text, not meaning; the AI does not read old conversations unless you reopen and continue them or save a summary to memory.
- The access token is stored unencrypted in app-private storage.
- Live replies need a deployed backend and a Gemini key whose free-tier quota and policy are set by Google.
- Default Flutter launcher icon; debug-key signing.
- Keep `AppInfo.version` in `lib/utils/app_info.dart` in sync with `pubspec.yaml`.
