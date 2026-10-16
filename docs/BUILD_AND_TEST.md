# Build and test

## Backend (needs Node 20+; no `npm install` required)
```bash
cd Backend
for f in *.js; do node --check "$f"; done   # syntax check
npm test                                      # node --test
# run locally (never commit real values):
GEMINI_API_KEY=... APP_ACCESS_TOKEN=... node index.js
```

## Android patch scripts (needs Python 3)
```bash
python3 -m unittest discover -s tool -p "test_*.py" -v
```

## Flutter app (needs Flutter stable, Dart >= 3.5, JDK 17, Android SDK)
```bash
bash tool/bootstrap_android.sh      # generates + patches android/ (once)
sudo apt-get install -y libsqlite3-dev   # Linux only: for database tests
flutter pub get
flutter analyze
flutter test
flutter build apk --debug           # or --release
# APK: build/app/outputs/flutter-apk/
```
Or push to GitHub: the **Build Android APK** workflow runs all of the above plus the backend job.

## Manual device checklist (Phase 1 could not do these)
1. Install the APK; confirm the lock prompt appears and cancelling keeps the app locked.
2. Chat in DEMO MODE with airplane mode on (must work).
3. Settings → backend URL + token → Test connection → send a message.
4. Settings → Face detection: capture, check "sample saved", delete it. Then check that no photo remains in the app cache (`adb shell run-as com.almus.almus_ai ls cache`; debug builds only).
5. Microphone dictation and read-aloud.
6. Confirm `adb backup`/Auto Backup is refused: `adb shell dumpsys package com.almus.almus_ai | grep -i allowBackup` (expect no ALLOW_BACKUP flag).
