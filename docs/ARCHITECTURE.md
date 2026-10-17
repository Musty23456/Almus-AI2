# ALMUS AI — Architecture (as inspected in Phase 1)

This describes the code as it exists, not the roadmap. Version 0.9.0+9.

## Overview

```
Android phone (Flutter app)                         Your server (Node.js, no dependencies)
┌──────────────────────────────────────────┐        ┌─────────────────────────────┐
│ UI screens ─ controllers ─ services      │ HTTPS  │ app.js  (routing, auth,     │   HTTPS   ┌────────┐
│    │             │            │          │ ─────► │          rate limits)       │ ────────► │ Gemini │
│    │             │      BackendClient    │ Bearer │ validate.js / gemini.js     │ API key   │  API   │
│    ▼             ▼                       │ token  │ config.js (env variables)   │ (header)  └────────┘
│ SQLite (conversations, memories)         │        └─────────────────────────────┘
│ SharedPreferences (settings, lock prefs) │
│ Android BiometricPrompt (local_auth)     │   The Gemini API key exists ONLY on the server.
│ ML Kit face detection (prototype)        │
└──────────────────────────────────────────┘
```

## Flutter app (`lib/`)

| Area | Files | Role |
|---|---|---|
| Entry | `main.dart`, `app.dart` | `main` opens SQLite (falls back to in-memory if it fails), builds the app lock and voice engines, then `AlmusApp`. `AlmusApp` wires settings, backend client, chat engine and wraps everything in `AppLockGate`. |
| Navigation / state | `screens/app_shell.dart` | Bottom `NavigationBar` with an index (no Navigator routes for tabs): Home, Chat, History, Memory, Settings. State management is plain `ChangeNotifier` / `ValueNotifier` controllers passed by constructor; no state-management package. |
| Chat | `controllers/chat_controller.dart`, `screens/chat_screen.dart` | Owns the open conversation, robot state, saves messages through a `ConversationRepository` on a serial write queue. A storage failure never blocks chatting. |
| Chat engines | `services/chat_service.dart`, `routed_chat_service.dart`, `demo_chat_service.dart`, `backend_client.dart` | `RoutedChatService` uses the backend when a URL is saved in Settings, otherwise the scripted **DEMO** engine. `BackendClient` calls `POST /v1/chat`, `GET /health`, `GET /v1/models`. |
| Storage | `data/app_database.dart` + `sqlite_*_repository.dart` | SQLite file `almus_ai.db`, **versioned migrations** (v1 conversations/messages, v2 memories/prefs/flags), `PRAGMA foreign_keys=ON`. Repositories convert DB errors to generic `StorageException`s (no content in messages). In-memory repositories are the fallback and test doubles. |
| Memory | `controllers/memory_controller.dart`, `services/memory_*.dart`, `sensitive_filter.dart` | User-controlled facts. Suggestions are never saved without confirmation; secrets/IDs are blocked, personal topics need explicit confirmation. Retrieval is local keyword (BM25-style) scoring; only the few selected memories are sent with a live request. |
| Voice | `voice/*` | `speech_to_text` + `flutter_tts` behind interfaces, a state machine and `VoiceController`. Stops on background, lock and conversation change. |
| Lock | `security/*`, `widgets/app_lock_gate.dart`, `screens/lock_screen.dart` | `AppLockController` decides visibility: content shows only after Android's BiometricPrompt reports success (or the lock is off). `FLAG_SECURE` via the `almus.ai/privacy` channel (Kotlin added by `tool/patch_android_biometric.py`). |
| Avatar | `avatar/*`, `widgets/robot_avatar.dart` | Code-drawn 2.5D avatar, six states, capped at 30 fps; optional `assets/avatar/avatar_profile.json`. |
| Face recognition (Phase 6) | `lib/face/`, `screens/face_recognition_screen.dart` | Camera still -> ML Kit detection -> quality gate -> alignment -> embedding (model-pluggable, none bundled) -> calibrated match against an encrypted template vault. **Not used for unlock.** |

### Which operations need the network?
Only: sending a chat message in live mode (`BackendClient.chat`) and the **Test connection** button in Settings. Opening the app, history, search, memory, settings, lock, avatar and local storage never call the network (verified by grep: the only `BackendClient` call sites are `RoutedChatService.reply` and `SettingsScreen._test`). Demo mode works without any server.

## Backend (`Backend/`)

Plain Node 20+ `http` server, ES modules, **zero npm dependencies**.

* `config.js` reads every setting from environment variables.
* `app.js`: `/health` (public), `/v1/chat` and `/v1/models` (Bearer `APP_ACCESS_TOKEN`, constant-time compare), per-client per-minute limit + global daily cap, body-size cap, generic error payloads.
* `validate.js`: strict request validation, history trimming, memory block cleaning.
* `gemini.js`: REST client; API key in the `x-goog-api-key` header only; optional fallback model; upstream errors mapped to safe messages.
* Tests: `*.test.js` using `node --test`.

## Security boundaries
* **Provider key**: server environment only. Not in the app, assets or repo.
* **Access token**: typed by the user, stored in app-private `SharedPreferences` (unencrypted at the app level; see KNOWN_LIMITATIONS.md).
* **Lock**: hides UI; does not encrypt the SQLite file.
* **Backups**: the Android patch sets `allowBackup="false"` (Phase 1).
* **Logging**: no `print`/`debugPrint` in app code; backend logs method, path, status, duration and error code only.

## Build pipeline
`android/` is not stored in the repo. `tool/bootstrap_android.sh` (used by CI and locally) runs `flutter create`, restores project files, and applies `tool/patch_android_manifest.py` and `tool/patch_android_biometric.py`.

## Phase 4 update: provider orchestration (backend 0.4.0)

```
app.js ─ validate (incl. routing) ─► ai/orchestrator.js ─► ai/registry.js ─► adapters/gemini.js ──► gemini.js (verified client)
                                      │ plan: primary, then          │                 ├► adapters/openaiCompat.js (Groq, OpenRouter, generic)
                                      │ consented fallbacks          └ live model cache └► any module satisfying the provider contract
                                      ├ ai/health.js    (states, circuit breaker)
                                      ├ ai/backoff.js   (exponential backoff + jitter)
                                      ├ ai/errors.js    (categories + retry/fallback/health policy table)
                                      └ ai/messages.js  (neutral messages, system prompt, token estimate)
redact.js masks secrets in every log line.
```
App side: `lib/ai/` (provider models, routing preferences, status controller), `screens/ai_providers_screen.dart`.
`RoutedChatService` sends `routing` only when customised and records which provider answered (`ReplyProvenanceSource`).
Full reference: `docs/PROVIDERS.md`.

