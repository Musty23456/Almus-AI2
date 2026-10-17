# Face recognition: biometric privacy (Phase 6)

## What is stored, where, and why

| Data | Stored? | Where | Why |
|---|---|---|---|
| Camera pictures | **No.** Deleted right after each is processed (also on failure). | Cache file for a moment only | Needed once, to find and align the face |
| Face templates (embeddings: lists of numbers) | Yes, only after explicit consent | `almus_face_vault.bin`, app-private, **AES-256-GCM** encrypted | To compare a later scan with enrolled people |
| Display name | Yes (inside the encrypted vault) | same | To show who matched |
| Encryption key | Yes | Android Keystore-backed secure storage (`flutter_secure_storage`), separate from the vault file | To decrypt the vault |
| Consent record (wording version + time) | Yes | App-private preferences | To prove consent exists and for which wording |
| Scanning-sound on/off | Yes | App-private preferences | User setting |

Not stored: raw images, similarity scores, scan history, results, anything
about failed scans.

## Consent

* Nothing is captured for enrollment before the user agrees to the full text
  in `lib/face/face_consent.dart` (what is stored, what is not, where, what
  it is for, what it cannot protect against, how to delete).
* The consent is versioned. If the wording changes (`kFaceConsentVersion`),
  old consent no longer counts and the question is asked again.
* **Withdrawing consent deletes all face data immediately.**
* Scanning requires enrolled data but no second consent; enrollment is the
  point at which biometric data is created.

## Encryption and platform protection

* AES-256-GCM, random 96-bit nonce per write, file signature authenticated.
* The 256-bit key is random and kept in the Android Keystore-backed secure
  store. The vault file alone is useless without it.
* **Deleting** removes the file *and* the key (crypto-erase), then verifies
  both are gone. A leftover copy of the file cannot be decrypted.
* `android:allowBackup="false"` keeps the vault and key out of Android backups
  (set since Phase 1). The in-app Backup feature exports chats/memory only and
  does not read the face vault (checked: no reference in `lib/backup`).
* Limits: on a rooted or compromised phone, or while the phone is unlocked and
  the app is running, templates exist in memory in plain form. Dart cannot
  reliably wipe memory.

## Network

Nothing about faces is uploaded. No face image, template, score or result is
sent to the backend, Gemini or anyone else. A source-level test
(`test/face_privacy_static_test.dart`) fails the build if face code imports
`http`, sockets or the backend client. If a future phase ever wants to upload
anything, it needs a separate explicit consent and a documented reason.

## Logging

Face code does not call `print`, `debugPrint` or `log`, and never prints
embeddings (`FaceEmbedding.toString()` prints `<hidden>`). The same static
test enforces the first rule. Android's own system logs cannot be controlled
from here.

## Deleting data

* Settings > Face recognition > **Delete all face data** (templates + key).
* Delete one person from the list.
* **Withdraw consent** (also deletes).
* Uninstalling the app removes everything.
* The old Phase 9 prototype saved a plain JPEG of your face
  (`almus_face_sample.jpg`). Phase 6 deletes that file and its preference the
  first time the face screen opens.

## Relationship with the app lock

Face recognition is an **extra feature**. The biometric app lock still uses
Android's `BiometricPrompt` through `local_auth`, unchanged. Face data is never
used to unlock the app or to approve anything.

## Not covered

No legal review (GDPR, BIPA or local biometric laws) was done. If anyone
other than you is enrolled, you are responsible for their consent under the
laws that apply to you.

## Phase 6b exception: cloud face verification (optional)

Everything above describes the **on-device** feature and is unchanged. The separate
"Cloud face verification" screen is the one exception: it UPLOADS face photos through your backend
to Luxand.cloud. See `docs/CLOUD_FACE_VERIFICATION.md`. The "Network" rule above still holds for all
code in `lib/face/*.dart`; the cloud code lives in `lib/face/cloud/` and is checked by its own rules in
`test/face_privacy_static_test.dart`.
