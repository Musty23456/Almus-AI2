# ALMUS AI — Phase 3 Report: Reliable voice input and chat attachments

Input: Phase 2 project (0.10.0+10). Output: 0.11.0+11, one complete project ZIP. Existing conversations, memory,
backup/restore and navigation were not changed (additions only; see §7).

## 1. Honest status (read first)

| Check | Result |
|---|---|
| Flutter / Dart SDK in my environment | **Not available.** `flutter pub get / analyze / test / build` **NOT RUN** |
| ~100 new Dart tests (`test/attachment_*`, `speech_recognizer_session_test`, `voice_reliability_test`) | **Written, never executed.** Phase 2 tests (60) are also still unexecuted |
| New Dart code (~3,500 lines) | Reviewed by reading only; **may contain compile errors** |
| Backend `node --test` | **47 / 47 pass** (38 old + 9 new attachment tests) — this is real, executed |
| Python tool tests | **21 / 21 pass** (incl. camera-query manifest test) |
| Key text-extraction regexes (XLSX/DOCX/PDF scanning) | Cross-checked in Python against the test fixtures (executed); the Dart code itself was not |
| **Physical-device microphone behaviour** | **NOT TESTED AT ALL.** I have no phone. Everything about the microphone below is code review + fake-engine unit tests, reported separately from device results (§6) |

## 2. Part A — why the microphone was unreliable (code review, not device reproduction)
The speech layer already existed (Phase 6). Reading it against how Android's `speech_to_text` plugin behaves, I found
these defects. They are **probable causes**; I could not reproduce them on hardware.
1. **Final result lost.** Android sends status `notListening` *before* the final result. The old code ended the session
   on that status, so the final (most accurate) words were dropped and short phrases could come back empty.
   *Fix:* wait up to 0.9 s for the final result after `notListening`/`done`.
2. **Second tap could do nothing.** Status events of a cancelled session could arrive after a new session had started
   and ended it immediately. *Fix:* statuses are ignored until the session's own `listening` event.
3. **Engine never starting = stuck "Listening".** *Fix:* 7-second start watchdog → clear "speech service did not start" message.
4. **False "language not installed".** Some engines return an empty locale list. *Fix:* English then uses the engine
   default; Hausa is attempted by name and any engine refusal is explained. An empty locale id is no longer passed.
5. **Single initialisation attempt.** *Fix:* on failure with permission granted, one retry using the plugin's intent
   lookup; Bluetooth permission prompt avoided (`androidNoBluetooth`).
6. **UI said "Speak now" before the microphone was open.** *Fix:* "Starting the microphone…" until the engine reports
   `listening`; "Processing…" after Done.
7. **Quick re-tap → engine "busy".** *Fix:* a still-active engine is cancelled (and given 250 ms) before a new session.
8. **Keyboard competing for the microphone / covering the bar.** *Fix:* the keyboard is closed when listening starts.
9. Added: first-use consent dialog (no raw audio is ever recorded or uploaded by the app), recognized-text preview with
   **Retry / Discard**, **EN/HA** switch, permission/engine/Hausa guidance, `notStarted` problem.
Unchanged and already fine: permission is requested only on tap; lifecycle (background) interrupts listening; leaving the
screen cancels the microphone; controller disposal cancels the recognizer.
To make the session logic testable, the plugin sits behind a small `SpeechEngine` interface (`SpeechToTextEngine` is the
real adapter).

Hausa: supported **only if** the installed Android speech engine offers it. The app says so in the language menu and in
error messages and never falls back silently to another language.

## 3. Parts B–E — attachments
* `lib/attachments/`: models, `FileSniffer` (type from content, not name), `DocumentProcessor`, parsers
  (TXT/MD/LOG/JSON, CSV/TSV, DOCX, XLSX, PDF), `AttachmentController`, system pickers (`image_picker` + `file_picker`,
  content URIs handled by the plugins, no hard-coded paths), `AttachmentPlan` (what the AI will really get).
* Attach button + bottom sheet (image, take photo, document, PDF, text, CSV/spreadsheet); preview strip (thumbnail, name,
  type, size, "Reading…"/status, remove, up to 5); problem banner; chat-bubble file list.
* Validation: size (10 MB), extension, **real content type** (renamed files refused), corrupted/empty files, parser output
  (empty text refused), total text limit.
* **PDF**: own pure-Dart extractor (page tree, Flate, object streams, ToUnicode maps). It is *basic*: no OCR, no encrypted,
  LZW/ASCII85 or font-without-Unicode-map PDFs — those get an explicit message. Complex PDFs may extract text out of order.
  I chose this over a plugin to avoid a licence/native dependency; it is the least-proven part of this phase.
* **AI compatibility (Part E):** selection and analysis are separate. `ChatService` is unchanged; engines opt in via
  `AttachmentCapableChatService`. Gemini-through-backend: extracted text only. DEMO: nothing. Images: never analyzed
  (no connection supports them). Before sending, skipped files are listed (Cancel / Remove them / Send anyway); stored
  messages say "NOT analyzed". Nothing is uploaded until Send; no device path or URI ever leaves the phone.
* **Backend** (`/v1/chat`, service 0.3.0): optional `attachments:[{name,kind,text,truncated}]`; any other field
  (path, uri, base64…) or kind (image…) → 400; limits 5 files / 30,000 chars each / 60,000 total (env-configurable); body
  limit raised 64 KB → 400 KB; text is appended to the newest user turn between marker lines with fake markers defused,
  and the system prompt tells the model to treat it as data (prompt-injection mitigation); file text is not logged.
* Memory extraction sees only the words the user typed, not file text.

## 4. Test inventory (Dart ones are UNRUN)
* `speech_recognizer_session_test` (20): permission denied, missing engine (+ intent-lookup retry), Hausa unavailable, empty
  locale list, final-after-notListening race, no-final grace, stale status, start watchdog, error mapping, errors after
  cancel, listen throwing, quick re-tap, 3 sessions in a row, stop with silent engine.
* `voice_reliability_test` (14): permission/engine/Hausa notices, empty result, preview, micOpen, processing, interrupted
  session, 5 sessions, retry, late callbacks, leaving the screen, backgrounding.
* `attachment_parsers_test` (37): all parsers incl. Hausa text, BOM/UTF-16, invalid UTF-8, empty, CSV quoting, DOCX/XLSX,
  PDF (plain, Flate, TJ, ToUnicode, bfrange, undecodable fonts, scans, encrypted, truncated), sniffing, renamed files,
  unsupported types, oversize, corrupted, isolate path, no content in error messages.
* `attachment_controller_test` (14): picking, cancel, permission error, mixed good/bad files, read failure, limits,
  duplicates, removal (also mid-read), disposal mid-read, state kept across screens, total-text limit.
* `attachment_chat_test` (9): planning, footer, text sent to engine, image not analyzed, mixed, DEMO, file-only, empty, failure.
* `attachment_ui_test` (8): attach sheet, chip/status/remove, error banner, send-anyway/remove-them dialog, consent,
  recognized-text preview with Retry/Discard, language switch.
* Backend 9 new (run, pass). Python 1 new (run, pass).
Not automated: real pickers, camera, real speech engine, real PDFs from real producers.

## 5. Risks to check first when you build
1. API names written from memory: `SpeechToText.androidNoBluetooth` / `androidIntentLookup` / `SpeechConfigOption`
   (speech_to_text 7), `ImagePicker.pickMultiImage()`, `archive` `findFile`, `file_picker` calls. A mismatch shows in `flutter analyze`.
2. `speech_to_text` option names are the most likely compile error; if they do not exist delete the `options:` argument in
   `SpeechToTextEngine.initialize`.
3. PDF extractor on real-world files.

## 6. Physical-device checklist (microphone results must be reported separately)
Mic: fresh install → tap mic → consent → Android permission → speak English → Done → "Heard" box; deny permission → guidance;
airplane mode → network message or on-device result; switch to HA with/without Hausa installed; tap mic 5× quickly; background
the app while listening; rotate; use with keyboard open; Bluetooth headset connected.
Files: one of each type from Downloads and from Google Drive (content URI); photo from camera; a PDF with text, a scanned PDF,
a renamed file, a 12 MB file, an empty file; remove chips; send with real backend and check the reply refers to the document.

## 7. Files
New: `lib/attachments/*` (9), `lib/widgets/attachment_widgets.dart`, `lib/voice/voice_consent.dart`, 7 test files + 2 fakes/fixtures,
`docs/VOICE_AND_ATTACHMENTS_GUIDE.md`, this report. Modified: `speech_recognizer.dart`, `voice_controller.dart`, `chat_screen.dart`,
`chat_controller.dart`, `chat_message.dart`, `message_bubble.dart`, `routed_chat_service.dart`, `backend_client.dart`, `app.dart`,
`main.dart`, `app_shell.dart`, `app_info.dart`, `pubspec.yaml` (version only), `tool/patch_android_manifest.py` (+camera query),
Backend (`validate.js`, `gemini.js`, `app.js`, `config.js`, tests), test fakes, CHANGELOG, KNOWN_LIMITATIONS.
No database migration; no new packages (archive, file_picker, image_picker, speech_to_text were already dependencies).
