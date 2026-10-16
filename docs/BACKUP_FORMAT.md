# ALMUS AI backup format (schema version 1)

Written by app 0.10.0+. All text is UTF-8; JSON is used everywhere, so Hausa
characters (Ɓ ɗ ƙ ƴ …) and any other Unicode are stored unchanged. Times are
UTC ISO-8601 with milliseconds (`2026-01-01T10:00:00.000Z`).

Readers refuse any `schema_version` higher than they know. Raise the version
only for changes older readers cannot understand.

## 1. Complete backup (`.zip`, unencrypted)

```
manifest.json
data/conversations.json
data/memories.json
data/settings.json        (present when settings are included)
```

`manifest.json`
```json
{
  "format": "almus-ai-backup",
  "schema_version": 1,
  "app": {"name": "ALMUS AI", "version": "0.10.0", "build": "10"},
  "created_at": "2026-01-01T12:00:00.000Z",
  "encryption": "none",
  "contents": {"conversations": 2, "messages": 4, "memories": 1, "settings": true, "attachments": 0},
  "files": [{"path": "data/conversations.json", "sha256": "…", "bytes": 1234}],
  "notes": "…"
}
```
Every listed file is checked against its SHA-256 and the counts in `contents`
must match the data; otherwise the backup is rejected as damaged.

`data/conversations.json`: `{"schema_version":1,"conversations":[Conversation…]}`

Conversation
```json
{"id":"c…","title":"…","created_at":"…","updated_at":"…","message_count":2,"metadata":{},
 "messages":[{"id":"m…","conversation_id":"c…","index":0,"role":"user|assistant",
   "content":"…","created_at":"…","status":"sent|error","engine":"DEMO|GEMINI","attachments":[]}]}
```
Messages are stored oldest first; the array order is authoritative (`index` is
informational). Relationships: `conversation_id` must equal the parent id.
Ids must be unique inside the file (message ids globally).

`attachments` is always empty: this app version has no attachment feature. Imported
non-empty lists are ignored with a warning.

`data/memories.json`: `{"schema_version":1,"memories":[{"id","category","text","created_at","updated_at","source_conversation_id","status":"confirmed|suggested","metadata":{}}]}`
`category` is one of profile, preference, learning, project, goal, fact, summary.
`status` is the user-confirmation state.

`data/settings.json`: `{"schema_version":1,"memory_enabled":true|false|null,"conversation_memory_off":["conversation id",…]}`

**Never included:** Gemini/provider keys, the backend address, the access token,
app-lock and face data, voice preferences.

## 2. Encrypted backup (`.almusenc`)

An ordinary complete-backup ZIP, encrypted. Layout:

| bytes | content |
|---|---|
| 8 | ASCII `ALMUSENC` |
| 1 | envelope version (1) |
| 4 | header length, big-endian |
| n | header JSON (UTF-8) |
| … | AES-GCM ciphertext followed by the 16-byte tag |

Header
```json
{"format":"almus-ai-encrypted-backup","envelope_version":1,"cipher":"AES-256-GCM",
 "kdf":"PBKDF2-HMAC-SHA256","kdf_iterations":600000,"salt":"<base64, 16 bytes>",
 "nonce":"<base64, 12 bytes>","inner":"almus-ai-backup-zip","app_version":"0.10.0","created_at":"…"}
```
* Key = PBKDF2-HMAC-SHA256(password as typed, UTF-8; salt; iterations) → 256 bits.
* AES-256-GCM, random nonce, **additional authenticated data = everything before
  the ciphertext** (magic, version, length, header). Editing the header makes
  decryption fail.
* Password and key are never stored. Wrong password and damaged file look the
  same on purpose (GCM cannot tell them apart).
* Accepted iteration range when reading: 1,000 – 5,000,000. New files use 600,000.
* Minimum password length when creating: 8 characters.

## 3. Structured JSON export (`.json`)

```json
{"format":"almus-ai-export","schema_version":1,"kind":"conversations|memories|all",
 "app_version":"0.10.0","exported_at":"…","conversations":[…],"memories":[…]}
```
Same Conversation / Memory objects as above. Not encrypted.

## 4. Readable transcripts

* **TXT**: header `ALMUS AI conversation transcript`, then per conversation a line of 64 `=`,
  `Title:`, `Conversation ID:`, `Created:`, `Updated:`, `Messages:`, a line of 64 `-`, then for each
  message `[ISO time] You|Almus (user|assistant) | id: … | engine: … | status: …` followed by the text,
  every line indented by four spaces.
* **Markdown**: a heading per conversation/message plus hidden `<!-- almus:conversation {json} -->` and
  `<!-- almus:message {json} -->` comments carrying ids and times.

Both can be imported again. Line endings are normalised to `\n`; a message that
itself contains a line identical to one of the structural lines above could be
misread — use JSON/ZIP when exact fidelity matters.

## 5. Importable foreign formats (only what is implemented and tested)

1. ALMUS ZIP, encrypted backup, structured JSON, TXT, Markdown (above).
2. **Generic JSON** (documented, not tied to any application):
   * `{"conversations":[{"id"?,"title"?,"created_at"?,"messages":[…]}]}`, or a list of such
     conversations, or `{"title"?,"messages":[…]}`, or a bare list of messages.
   * message: `role` = `user`|`assistant` (`system` is skipped), text in `content` (or `text`),
     optional `id`, optional `timestamp`/`created_at` (ISO-8601, or Unix seconds/milliseconds).
   * Missing ids are derived from the content (stable, so importing twice finds the duplicates).
     Missing times use the import time (a warning is shown).
3. **Plain transcript**: lines starting `You:`/`User:`/`Assistant:`/`Almus:` (continuation lines
   belong to the previous speaker). No timestamps.

**No adapter exists for ChatGPT, Gemini, Claude, WhatsApp or any other application's own export.**
Such files are refused or, if they happen to match the generic shape, imported as generic JSON —
which is not a compatibility claim.

## 6. Duplicate and conflict rules (merge)

* Conversation with an existing id: kept as is (title/time never overwritten); only missing messages
  (by id) are added; `updated_at` can only move forward.
* Message id that exists in the same conversation: duplicate, skipped.
  Message id that exists in a *different* conversation: conflict, skipped and reported.
* Memory with an existing id, or the same category + text (ignoring case/spacing): duplicate, skipped.
* Settings: only the per-chat "memory off" switches are added; the master memory switch is not changed.

**Replace** deletes the selected sections (conversations+messages, memories, memory settings) inside the
same transaction that inserts the backup. Everything else in the app is untouched.
