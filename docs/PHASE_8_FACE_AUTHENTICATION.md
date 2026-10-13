# ALMUS AI — Phase 8: Face authentication

## Goal
Use the phone's trusted Android biometric authentication for access control, including face authentication when the device supports and has enrolled it. The application does not implement its own face-template matcher.

## What is implemented
- Security screen reports when Android's biometric list includes a face biometric.
- The lock button uses face-themed iconography when face is reported, otherwise a fingerprint icon.
- Authentication still goes through `local_auth` / Android BiometricPrompt; only a successful OS response unlocks private screens.
- Device PIN/pattern/password fallback remains available when the user allows it, or when no biometric is enrolled.
- App version is advanced to `0.8.0+8`.

## Important platform limitation
The generic Android biometric prompt generally selects from the enrolled biometrics allowed by the operating system. The app cannot guarantee face-only authentication on every Android device, nor can it reliably distinguish face from fingerprint on all Android versions. If a face is not reported or enrolled, the app must not claim face recognition is available.

This is **native face authentication**, not a custom AI face-recognition model. The app does not open the camera for this feature, capture face photos, create face embeddings, or upload biometric data. The eye animation is only a visual indicator and never decides access.

## Setup and test
1. On an Android phone, set a secure screen lock and enrol face unlock in Android Settings if supported.
2. Install the APK produced by GitHub Actions.
3. Open ALMUS AI and authenticate. Android may show its face prompt or another accepted biometric according to the device and OS policy.
4. Test cancellation and failed authentication; private screens must remain locked.
5. If face unlock is not available, use an enrolled fingerprint or the allowed device credential.

## Security and testing notes
- Do not treat the animation or face-presence detection as identity verification.
- Face unlock security varies by device. Prefer a strong biometric or device PIN if the phone's face unlock is not documented as secure.
- The SQLite chat/memory database is not encrypted by this app-lock feature.
- Automated tests use fake biometric services; test on physical Android hardware before production release.
