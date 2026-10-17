# Cloud face verification (Phase 6b, optional)

A 1:1 check ("is this the enrolled person?") using Luxand.cloud, because no on-device recognition model
could be bundled (see `FACE_MODEL_LICENSING.md`). It is OFF until the user agrees to a separate consent.

## Data flow

phone camera -> (one JPEG, base64) -> YOUR backend `/v1/face/*` -> Luxand.cloud

* The Luxand API token exists only in the backend environment (`LUXAND_API_TOKEN`). The app never has it.
* The app talks to the backend with `APP_ACCESS_TOKEN`. Face routes refuse to work without it.
* The phone keeps only: a name the user typed, and Luxand's anonymous person id (Android Keystore-backed secure storage).
* Luxand receives a random label (`almus-xxxxxxxxxxxx`), not the real name. It keeps the face data on its servers.
* Camera files are deleted right after use. Photos are held in memory only while being sent.
* One person at a time. Re-enrolling deletes the old person at the service first; if that fails, nothing changes.
* Delete / withdraw consent: the service is asked first. If it cannot be reached, the app says "NOT deleted" and keeps the link so it can retry.

## Setup (Render)

1. In Luxand: rotate any token that was ever pasted somewhere public. Create/copy the new token.
2. Render env: `LUXAND_API_TOKEN`, `APP_ACCESS_TOKEN` (already set). Leave `LUXAND_MIN_SIMILARITY` empty for now.
3. App: Settings -> Cloud face verification -> CHECK BACKEND SETUP (it will say matching is off: that is correct).
4. Calibrate (below), then set `LUXAND_MIN_SIMILARITY` and turn `FACE_RETURN_SCORE` off.

## Calibrating the threshold (required, no default)

Set `FACE_RETURN_SCORE=true` temporarily. Enrol yourself, then verify many times (different light, angles, days) and note
the scores; have other people (who agreed) try to verify against YOUR enrolment and note those scores too. Choose a threshold
above the highest impostor score you saw and below most of your own. `tool/calibrate_threshold.py` shows the idea for the
on-device feature. Re-check after any change by Luxand.

## Not verified yet (do before relying on it)

* The verify answer field `similarity` (0..1) and the delete call `DELETE /person/{uuid}` are not in the page this was built from.
  Make one real verify and one real delete call. If a field differs, `Backend/luxand.js` is the only place to change.
* Luxand's licence, price, retention period, data location and whether it offers liveness were not checked.
* The Dart code was not compiled or run. GitHub Actions is the first real run.

## Honest limits

* No proven anti-spoofing: a photo or replayed video may be accepted.
* The result is decided in the app from the backend's answer; a rooted/modified phone could fake it.
* Not a lock. The app lock stays with Android's biometric prompt.
* Biometric laws (GDPR, BIPA, local law) may apply. No legal review was done.
