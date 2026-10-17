# Known limitations (end of Phase 1)

## Not verified by running (environment limits)
1. **No Flutter/Dart test, analysis or build was executed in Phase 1** (the working environment had no Flutter SDK and no network). Everything under `lib/` and `test/` was reviewed by reading only. The two Dart edits made in Phase 1 and the new Dart test have **not been compiled**.
2. **Nothing was tested on a physical Android device**: biometric prompt, FLAG_SECURE, microphone, TTS, camera, ML Kit.
3. The Gemini round trip was not run against the real API (backend tests use a mocked `fetch`).

## Product gaps relative to the roadmap
* No image/document attachments, backup/export/import, multiple AI providers, offline tools, device actions, or real face recognition.
* Replies are not streamed.
* Voice is limited to Android system engines; the mouth animation is a generic loop, not lip-sync.

## Security / privacy
* **Access token is stored unencrypted** in app-private SharedPreferences. Recommended Phase 2 change: `flutter_secure_storage` (Android Keystore). Not done now to avoid a new dependency without device testing.
* **SQLite database is not encrypted.** The lock only hides the UI. Anyone with root/adb access to an unlocked device can read it.
* **Face recognition (Phase 6)** has no bundled model, so it cannot recognise anyone yet; it has no liveness protection and is not a security feature. The Phase 9 face photo is deleted automatically. See `PHASE_6_REPORT.md`.
* **Chat text is sent to your backend and to Google Gemini** in live mode. The sensitive-data filter protects *saved memories* only; it does not filter what you type in chat.
* `/health` is public and reveals the model name, whether a Gemini key is configured, and whether auth is required. When the server is misconfigured, the 503 message names which environment variables are missing (never their values).
* Backend rate limits and the daily cap are in memory and reset on restart/redeploy; with several instances each has its own counters.

## Build / project
* `android/` is generated at build time, so builds depend on whichever Flutter "stable" is current. There is **no `pubspec.lock`**; dependency versions are not pinned. Consider committing a lock file and pinning the Flutter version in CI.
* Release APKs are signed with Flutter's default debug key unless you add your own signing configuration. Do not publish such an APK.
* `allowBackup="false"` means chats are not restored from Google backup on a new phone until Phase 2 adds export/import. To keep the Android default, set `ALLOW_BACKUP = None` in `tool/patch_android_manifest.py`.
* `flutter_lints` info-level hints are tolerated by CI (`--no-fatal-infos`).

## Phase 2 additions (backup and restore)
* **None of the Phase 2 Dart code or tests has been compiled or run** (no Flutter SDK in the working environment). Run `flutter pub get && flutter analyze && flutter test` first; expect to fix small compile errors.
* **Not tested on a device**: the Android save/open dialogs of `file_picker`, restoring after a real uninstall/reinstall, and PBKDF2 speed (600,000 iterations, run in a background isolate) on a real phone.
* No attachments exist in the app, so none are backed up. Voice, app-lock, face and backend settings are deliberately excluded.
* Backups and exports are not encrypted unless a password is chosen. A forgotten password cannot be recovered. Passwords are used exactly as typed (no Unicode normalisation).
* Whole files are read into memory (limit 256 MB file / 512 MB unpacked); building a very large ZIP runs on the UI isolate and may briefly freeze the screen.
* The file picker leaves a temporary copy of an imported file in the app cache; the app asks Android to delete it after each import (best effort).
* No ChatGPT/Gemini/Claude/WhatsApp export adapters exist.
* Restore does not run while the assistant is writing a reply.

## Phase 3 additions (voice and attachments)
* **Nothing in Phase 3 (or Phase 2) Dart code has been compiled or run**; the microphone has not been tested on a phone.
* Voice fixes are based on code review of known Android behaviour, not on a reproduced failure.
* Hausa recognition depends on the phone's speech engine. The speech service (not ALMUS AI) may send audio online.
* PDF text extraction is basic: no OCR, no encrypted PDFs, no LZW/ASCII85 streams, no fonts without a Unicode map; reading order may be imperfect.
* Images are attachable but never analyzed (the backend/Gemini route receives text only). Old .doc/.xls/.ppt, PPTX, ZIP and HEIC are not supported.
* Attached file content is not stored in the chat history or in backups; only a list of file names and sizes is. Follow-up questions in later turns cannot see the file text.
* Dates in XLSX appear as Excel serial numbers; formulas show their last saved value.
* Picker temporary copies in the app cache are cleaned best-effort (`file_picker`); `image_picker` copies are left to Android's cache cleanup.

## Phase 4 additions (multi-provider)
- The new Flutter code and its ~40 Dart tests were never compiled or run (still no Flutter SDK). Backend: 105 tests executed and passing, all with mocked providers; **no live provider call was made**, so real Groq/OpenRouter behaviour, current model names and limits are untested.
- Provider adapters were written from documentation read on 15 Oct 2026. Error body shapes and rate-limit semantics can differ from what I saw; unknown shapes fall back to safe categories (`unknown`, no retry).
- No real adapter supports images; image attachments are still not analysed.
- Free-tier status is declared by the operator (`*_COST_POLICY`, `GEMINI_BILLING`); the code cannot verify billing. A fallback with undeclared cost is refused.
- Health state and the model cache are in memory: they reset when the backend restarts or sleeps (free hosts do this).
- Retries can still cause a duplicate provider-side request in rare cases (a connection that drops after the provider accepted it); this is why retries after timeouts/5xx are limited to providers declared free-only.
- Cancellation aborts our call; the provider may already have processed (and billed) the request.
- `OPENROUTER_DATA_COLLECTION=deny` may leave no free model available; OpenRouter also routes between its own hosts internally.
- The access token is still stored unencrypted on the phone (Phase 1). User-supplied provider keys are deliberately not supported (see `docs/PROVIDERS.md` §8).
- The Dockerfile change could not be built here (no Docker); the production file layout was booted and queried manually instead.
- The app has no local calculator or deterministic text tools, so none were preserved or added.

