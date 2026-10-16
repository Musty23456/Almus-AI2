# Changelog

## 0.12.0+12 — Phase 4: Multi-provider AI orchestration and fallback (Dart code not compiled or run; see PHASE_4_REPORT.md)

### Backend (0.4.0, executed tests: 105/105)
- Provider abstraction (`Backend/ai/`): adapters for Gemini (existing client preserved), Groq, OpenRouter and any OpenAI-compatible service; contract validated by `assertProvider`.
- Orchestrator: capability-aware routing, error classification (15 categories), bounded retries with exponential backoff + full jitter, `Retry-After` handling, per-provider circuit breaker and health tracking, request deadline, cancellation on client disconnect.
- Fallback only with user consent per provider, operator eligibility and declared cost; memory notes and file text withheld from fallbacks unless allowed.
- No hardcoded model names for new providers: live model lists, `auto` selection, OpenRouter paid models blocked by price.
- New endpoints: `GET /v1/providers`, `POST /v1/providers/check`, `GET /v1/providers/<id>/models`; `routing` field on `/v1/chat`; `/health` adds `aiConfigured`.
- Secret redaction on all logs; sanitized client errors with `details` (categories only); tight rate limit on health checks.
- Dockerfile now copies the `ai/` folder.

### App
- Settings → **AI providers** screen: local-vs-remote explanation, provider cards with honest status (never "working" before a real check), model chooser, capability/cost/data notes, main-provider choice, opt-in automatic fallback with per-provider consent, separate switches for memory/file sharing.
- Replies are labelled with the provider that answered; a notice explains any fallback.
- `routing` is sent only when the user changed something, so default requests are unchanged.
- Version 0.12.0+12.

## 0.11.0+11 — Phase 3: Reliable voice input and chat attachments (not yet compiled or run, see PHASE_3_REPORT.md)

### Voice
- Fixed probable causes of unreliable microphone: final result lost after `notListening`, stale status ending a new session, no start watchdog, false "language not installed" with empty locale lists, single init attempt, UI claiming "listening" early, keyboard/quick-retap conflicts.
- New: first-use consent, "Starting / Listening / Processing" states, recognized-text preview (Retry / Discard), EN/HA switch, clearer permission / engine / Hausa guidance. `SpeechEngine` interface for testing.

### Attachments
- Attach button + sheet (image, camera, document, PDF, text, CSV/spreadsheet), previews, removal, validation, real-content-type checks.
- Local parsers: TXT/MD/LOG/JSON, CSV/TSV, DOCX, XLSX, PDF (basic, no OCR).
- AI compatibility: only extracted text, only for engines that support it; images/unsupported files are clearly marked "NOT analyzed".
- Backend 0.3.0: optional validated `attachments` (extracted text only), delimited and defused in the prompt; body limit 400 KB.
- Manifest patch: camera query intent.

## 0.10.0+10 — Phase 2: Conversation and personal memory backup (not yet compiled or run, see PHASE_2_REPORT.md)

### Added
- Settings → **Backup & Restore**: export all / selected conversations (JSON, Markdown, TXT), export personal memory (JSON, Markdown), complete backup (ZIP, optional password), import with preview, merge or replace, progress and result messages, last-backup info.
- `lib/backup/`: versioned format (`docs/BACKUP_FORMAT.md`), ZIP codec with SHA-256 manifest, AES-256-GCM + PBKDF2-HMAC-SHA256 encryption, import adapters (ALMUS ZIP/encrypted/JSON/TXT/Markdown, documented generic JSON, plain "You:/Assistant:" transcripts), transactional SQLite store with rollback and post-import verification.
- Android system file picker/saver through `file_picker` (no storage permission, no network, no account).
- `tool/verify_backup.py` (+ tests): independent backup checker.
- Dependencies: `archive`, `crypto`, `cryptography`, `file_picker`.
- Tests: `test/backup_*.dart` (60 Dart tests, not run yet), `tool/test_verify_backup.py` (11, run).

### Changed
- App version 0.10.0+10; `ChatController.reloadAfterRestore()`; `RepositoryOpenResult.backupStore`.

### Not changed
Database schema (no migration), backend, app lock, `allowBackup=false`.

## Unreleased — Phase 1: audit and stabilization (app version still 0.9.0+9)

### Fixed
- **Chat could freeze on "THINKING"** if the chat engine threw a Dart `Error` (e.g. `StateError`, `TypeError`) instead of an `Exception`: `ChatController.send` now clears the busy flag and shows a generic error bubble for any failure. (`lib/controllers/chat_controller.dart`)
- **Face photos left in the app cache**: the temporary camera capture is now always deleted after enrollment succeeds, fails, finds no face or finds several. (`lib/screens/face_enrollment_screen.dart`)

### Security
- Android manifest patch now sets `android:allowBackup="false"` so the chat/memory database, backend token and face sample are not copied to Android cloud/adb backups. Reversible with `ALLOW_BACKUP = None` in `tool/patch_android_manifest.py`.
- Added `.gitignore` (was missing) covering `.env`, keystores, `key.properties`, build output, `node_modules`.

### Added
- `tool/bootstrap_android.sh`: one script that generates and patches `android/`, used by both CI and local builds; it restores project files if `flutter create` touches them.
- `tool/test_patch_scripts.py`: 9 unit tests for the Android patch scripts.
- `test/chat_robustness_test.dart`: regression tests for the chat fix (not yet run; see report).
- CI: new `backend` job (syntax check + `node --test`); Android job now runs the patch-script tests.
- Docs: `PHASE_1_REPORT.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN_LIMITATIONS.md`, `docs/BUILD_AND_TEST.md`.

### Not changed (deliberately)
UI, database schema (no migration needed), dependencies, biometric lock logic, backend code.
