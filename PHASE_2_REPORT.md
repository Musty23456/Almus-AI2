# ALMUS AI — Phase 2 Report: Conversation and Personal Memory Backup

**Input:** `Almus-AI2-Phase1.zip` (Flutter app 0.9.0+9, verified Phase 1). **Output:** app 0.10.0+10, one complete project ZIP.

## 1. Honest status (read first)

| Check | Result |
|---|---|
| Flutter / Dart SDK in my environment | **Not available** → `flutter pub get`, `analyze`, `test`, `build apk` **NOT RUN** |
| 60 new Dart tests (`test/backup_*.dart`) | **Written, never executed.** No claim that they pass |
| New Dart code (~3,000 lines) | Reviewed by reading only; **may contain compile errors** |
| `tool/test_verify_backup.py` (11 new) + existing patch tests (9) | **20 / 20 pass** (Python 3.12) |
| Backend `node --test` | 38 / 38 pass (backend unchanged) |
| Physical Android device | **Nothing tested** — including the save/open dialogs and restore after reinstall |

The Python tests exercise the *documented file format* (ZIP + manifest + checksums, and the
AES-256-GCM/PBKDF2 envelope) with an independent implementation. They prove the specification is
self-consistent and that its tamper/wrong-password rules work; they do **not** prove the Dart code
produces those bytes. The first real check is CI (`flutter analyze && flutter test`).

Because restore-after-reinstall has not been run on a phone, **I do not claim it works yet.** What exists:
the user chooses the save location with Android's own save dialog (outside private storage), and the
import screen reads from Android's file picker with no account or cloud. Verify with the device checklist in §7.

## 2. What was built
`lib/backup/` (models, ZIP codec, crypto, transcript writers/parsers, import adapters, store contract,
SQLite store, controller, file gateway) and `lib/widgets/backup_restore_section.dart`; wired through
`main.dart` → `app.dart` → `app_shell.dart` → `settings_screen.dart` (section "Backup & Restore").
Format: `docs/BACKUP_FORMAT.md`. Migration notes: `docs/DATABASE_MIGRATION_NOTES.md` (no schema change).
User instructions: `docs/BACKUP_USER_GUIDE.md`.

Requirement map
* §2 conversation export: all / selected / single, TXT, Markdown, JSON; ids, titles, roles, text, times, order, engine/status; Unicode preserved. Attachments: app has none (field reserved, always empty).
* §3 memory export: JSON + Markdown; id, text, category, created/updated, confirmation status, source chat.
* §4 complete backup: ZIP with manifest (schema version, app version, timestamp, counts, SHA-256 of each file), conversations (with messages), memories, memory settings. Secrets never exported (test checks the archive for token/URL/key words).
* §5 import: Android file picker; validate before touching data; preview with counts/duplicates/warnings; merge or replace; duplicates by id (+ memory text); one SQLite transaction, batches of 500, post-insert recount (mismatch → rollback); replace requires a confirmation dialog listing exactly what is deleted, with an optional safety backup, and only touches conversations/messages/memories/memory settings.
* §6 adapters: ALMUS ZIP/JSON/TXT/Markdown, documented generic JSON, plain "You:/Assistant:" text. **No third-party app export is claimed.** Unsupported files get specific messages.
* §7 encryption: AES-256-GCM, PBKDF2-HMAC-SHA256 (600,000 iterations, 16-byte salt, 12-byte nonce) via the `cryptography` package; parameters in an authenticated header; password/key never stored; wrong password or corruption → rejected with no change; UI labels encrypted (.almusenc) vs unencrypted (.zip) everywhere.
* §8 reinstall: SAF save/open through `file_picker`; no account/cloud/auto-upload; UI text states private storage is deleted on uninstall.
* §9 UI: all listed controls, progress bar with stage text, success/failure panel, last backup/restore line, preview screen with merge/replace.
* §10 tests: see §3.

## 3. Test inventory (all Dart tests UNRUN)
* `backup_format_test.dart` (28): empty/multi/empty-conversation/Unicode round-trips, 20,000-message ZIP, truncated ZIP, tampered checksum, unsupported schema, non-ALMUS ZIP, no credentials in archive, encryption round-trip/random salt/wrong password/bit flip/header edit/truncation/weak password/isolate path, JSON/TXT/Markdown round-trips with Hausa text and multi-line messages, invalid JSON, generic JSON (roles, epoch+ISO times), stable ids, plain transcripts, binary/empty files, duplicate ids, newer schema.
* `backup_store_test.dart` (18): export, selection, empty DB, merge (duplicates, no overwrite, partial merge, id conflict, repeated imports ×3, master switch kept, 20,000 messages), replace (counts, partial sections, empty backup, unrelated table untouched), rollback via a database trigger for replace and merge, error text has no chat content, Unicode in SQLite, real repository → fresh DB.
* `backup_controller_test.dart` (12): all export formats, selection, cancelled save, empty export, memory export, backup → "reinstall" into a fresh DB, encrypted flow with wrong then right password, weak password, invalid file, safety backup/cancel, blocked restore, result text.
* `backup_ui_test.dart` (2): card shows every action and exports; password mismatch is rejected.
* Python: 11 new (valid, empty, tamper, truncated, future schema, foreign ZIP, encrypted round trip, wrong/missing password, bit-flip/header edit, truncated encrypted) — **run, pass**.
Not covered: real file picker, device, UI of the preview screen beyond what is listed.

## 4. Decisions and trade-offs
* ZIP + JSON (not a SQLite copy): readable, versioned, schema-independent.
* Duplicate detection is by id (stable ids) — a message id that exists in another chat is skipped and reported, never overwritten.
* Merge never changes the master memory switch; replace applies it.
* Transcripts (TXT/MD) are best-effort for re-import (line endings normalised); JSON/ZIP are lossless.
* PBKDF2 chosen over Argon2 because it is available in the pure-Dart package with no native code; cost is mitigated by 600,000 iterations and a background isolate.

## 5. Risks to check first
1. `archive ^3.6.1`, `cryptography ^2.7.0`, `file_picker ^8.1.6` APIs were written from memory; a signature mismatch would show in `flutter analyze`.
2. `FilePicker.platform.saveFile(bytes:)` return value on cancel on Android (I treat `null` as cancel).
3. PBKDF2 duration on low-end phones.

## 6. Files
New: `lib/backup/*` (10), `lib/widgets/backup_restore_section.dart`, `test/backup_*.dart` (5), `tool/verify_backup.py`, `tool/test_verify_backup.py`, `docs/BACKUP_FORMAT.md`, `docs/BACKUP_USER_GUIDE.md`, `docs/DATABASE_MIGRATION_NOTES.md`, this report.
Modified: `pubspec.yaml`, `lib/main.dart`, `lib/app.dart`, `lib/screens/app_shell.dart`, `lib/screens/settings_screen.dart`, `lib/controllers/chat_controller.dart` (+`reloadAfterRestore`), `lib/data/repository_factory.dart`, `lib/utils/app_info.dart`, `test/widget_test.dart` (version text), `CHANGELOG.md`, `docs/KNOWN_LIMITATIONS.md`.

## 7. Manual device checklist
1. Create an encrypted backup, save to Downloads; confirm the file exists in the Files app.
2. Uninstall ALMUS AI, reinstall, Import backup, pick that file, enter password, check preview, Merge. Chats and memories return with Hausa text intact.
3. Wrong password → error, data unchanged. Cancel the picker → nothing changes.
4. Replace with the safety-backup box ticked; kill the app mid-progress on a large file; reopen: old data still complete.
5. `python3 tool/verify_backup.py <file>` on a computer reports OK.
