# Database migration notes (Phase 2)

**No schema change and no new migration.** `kMigrations` still ends at version 2; existing
installations keep their database as is.

Inspected before editing: tables `conversations`, `messages` (FK → conversations, role/status
CHECKs), `memories`, `memory_prefs`, `memory_conversation_flags`; models `Conversation`,
`ChatMessage`, `MemoryItem`; repositories (SQLite and in-memory); settings in SharedPreferences
(backend URL/token, voice, lock); no attachment storage exists.

Design consequences
* Message order is `created_at, rowid`. Backups store messages in that order and restore inserts in
  the same order, so the order is reproduced.
* Messages and memories have no "deleted"/"edited" columns, so those are not exported.
* The only new persisted values are three SharedPreferences keys: `backup_last_at`,
  `backup_last_label`, `backup_last_restore_at` (times and a short label, no content).
* `SqliteBackupStore` uses one `db.transaction`; it deletes (replace), inserts in batches of 500,
  recounts, and throws (rolling back) if the counts differ from the plan. Only the tables listed above
  are touched.
* Future change: add `Migration(3, …)` as usual and bump `kBackupSchemaVersion` only if the backup
  layout must change; old files stay readable because readers accept every version ≤ their own.
* New packages: `archive`, `crypto`, `cryptography`, `file_picker`.
