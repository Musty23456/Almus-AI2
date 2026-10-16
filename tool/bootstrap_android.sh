#!/usr/bin/env bash
# Generates and patches the android/ folder (it is not stored in the repository).
# The GitHub Actions workflow runs this same script, so local and CI builds match.
# Needs: flutter and python3 on PATH. Safe to run more than once.
#
#   bash tool/bootstrap_android.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f pubspec.yaml ] || [ ! -f lib/main.dart ]; then
  echo "Run this from the ALMUS AI project (pubspec.yaml and lib/main.dart missing)." >&2
  exit 1
fi

if [ ! -d android ]; then
  backup="$(mktemp -d)"
  trap 'rm -rf "$backup"' EXIT
  # `flutter create` must never change our own files; keep copies and restore them.
  for f in pubspec.yaml analysis_options.yaml README.md .gitignore; do
    if [ -f "$f" ]; then cp "$f" "$backup/$f"; fi
  done
  cp -R lib "$backup/lib"
  cp -R test "$backup/test"

  flutter create --platforms=android --org com.almus --project-name almus_ai --no-pub .

  for f in pubspec.yaml analysis_options.yaml README.md .gitignore; do
    if [ -f "$backup/$f" ]; then cp "$backup/$f" "$f"; fi
  done
  rm -rf lib test
  cp -R "$backup/lib" lib
  cp -R "$backup/test" test
fi

MANIFEST=android/app/src/main/AndroidManifest.xml
sed -i.bak 's/android:label="[^"]*"/android:label="ALMUS AI"/' "$MANIFEST" && rm -f "$MANIFEST.bak"
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed -i.bak 's|<application|<uses-permission android:name="android.permission.INTERNET"/>\n    <application|' "$MANIFEST" && rm -f "$MANIFEST.bak"
fi
# Phase 6: microphone permission, speech/TTS queries. Phase 1: allowBackup=false.
python3 tool/patch_android_manifest.py "$MANIFEST"
# Phase 7: USE_BIOMETRIC, FlutterFragmentActivity, FLAG_SECURE channel, AppCompat theme.
python3 tool/patch_android_biometric.py
grep -n 'android:label\|allowBackup\|INTERNET\|RECORD_AUDIO\|USE_BIOMETRIC\|RecognitionService\|TTS_SERVICE' "$MANIFEST"
