# ALMUS AI — Phase 9: On-device face detection and enrollment prototype

## Implemented
- New **Settings → Face detection & enrollment** screen.
- Captures a still image with the front camera via Android's camera intent.
- Runs Google ML Kit face detection on-device and accepts the capture only when exactly one face is detected.
- Saves the image to the app-private support directory and records its path in app preferences.
- Allows the user to re-enroll or delete the stored sample.
- No image is uploaded to the backend or sent to Gemini.
- App version advances to `0.9.0+9`.

## What this is not
Face detection locates a face and estimates facial geometry. It does not determine whose face it is. This phase does **not** implement face embeddings, identity matching, liveness detection, anti-spoofing, or app unlocking. A printed photo may pass a simple face detector, so this screen must never be used as an authentication factor.

The existing app lock remains protected by Android `local_auth` / BiometricPrompt. Do not change the lock controller to trust a face-detection result.

## Privacy
The captured image is stored in the app's private support directory and is not uploaded. The user can delete it from this screen. Treat the photo as sensitive biometric-adjacent personal data; obtain consent before enrolling anyone and never capture another person without permission.

## Build and test
1. Run `flutter pub get`.
2. Run `flutter analyze` and `flutter test`.
3. Build with the repository's GitHub Actions **Build Android APK** workflow.
4. On an Android device, open **Settings → Face detection & enrollment**, capture a clear single face, then test the no-face and multiple-face messages and the delete action.
5. Verify that app lock still uses the Android system authentication prompt.

## Work required before real identity recognition
A production recognition phase still needs a vetted face-embedding model (for example a licensed and maintained TFLite-compatible model), preprocessing/alignment, calibrated similarity threshold testing across different lighting and devices, liveness/anti-spoofing, secure template storage, user consent/deletion flows, and independent security review. Do not market Phase 9 as real identity recognition or use it to unlock private data.
