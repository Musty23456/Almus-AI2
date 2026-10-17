#!/usr/bin/env python3
"""Adds the Android declarations that Phase 6 voice and face scanning need to AndroidManifest.xml.

Run after `flutter create` (the CI workflow does this). Safe to run twice.

  - RECORD_AUDIO permission: the microphone, requested at run time only when
    the user taps the microphone button.
  - <queries> entries: on Android 11+ the app must declare that it talks to a
    speech-recognition service and a text-to-speech engine, otherwise the
    system hides them and voice reports "not available".
  - android:allowBackup="false" (Phase 1 security hardening): keeps the local
    chat/memory database, the backend access token and the private face
    sample out of Android cloud backups and adb backups. Set
    ALLOW_BACKUP = None below to leave the Android default untouched.

Usage: python3 tool/patch_android_manifest.py [path/to/AndroidManifest.xml]
"""
import re
import sys

DEFAULT = "android/app/src/main/AndroidManifest.xml"

PERMISSIONS = [
    '<uses-permission android:name="android.permission.RECORD_AUDIO"/>',
    # Phase 6: front camera stills for optional face recognition. Requested
    # at run time, only when the user opens a scan or enrollment.
    '<uses-permission android:name="android.permission.CAMERA"/>',
    # The camera is optional: the app still installs on phones without one.
    '<uses-feature android:name="android.hardware.camera" android:required="false"/>',
]

# Phase 1: do not let Android copy private app data into backups.
# Use None to skip this change.
ALLOW_BACKUP = "false"

QUERY_INTENTS = {
    "android.speech.RecognitionService":
        '<intent>\n            <action android:name="android.speech.RecognitionService"/>\n        </intent>',
    # Phase 3: "Take photo" in the chat attachment sheet opens the camera app.
    "android.media.action.IMAGE_CAPTURE":
        '<intent>\n            <action android:name="android.media.action.IMAGE_CAPTURE"/>\n        </intent>',
    "android.intent.action.TTS_SERVICE":
        '<intent>\n            <action android:name="android.intent.action.TTS_SERVICE"/>\n        </intent>',
}


def set_allow_backup(text: str, value: str) -> str:
    """Sets android:allowBackup on the <application> element (idempotent)."""
    match = re.search(r"<application\b[^>]*>", text, re.DOTALL)
    if not match:
        return text
    tag = match.group(0)
    if re.search(r'android:allowBackup\s*=\s*"[^"]*"', tag):
        new_tag = re.sub(
            r'android:allowBackup\s*=\s*"[^"]*"',
            'android:allowBackup="' + value + '"',
            tag,
        )
    else:
        new_tag = tag.replace(
            "<application", '<application android:allowBackup="' + value + '"', 1
        )
    return text[: match.start()] + new_tag + text[match.end():]


def patch(text: str) -> str:
    # 0. Backups.
    if ALLOW_BACKUP is not None:
        text = set_allow_backup(text, ALLOW_BACKUP)

    # 1. Permissions go right before <application.
    for perm in PERMISSIONS:
        name = re.search(r'android:name="([^"]+)"', perm).group(1)
        if name not in text:
            text = text.replace("<application", perm + "\n    <application", 1)

    # 2. Queries.
    missing = [xml for key, xml in QUERY_INTENTS.items() if key not in text]
    if missing:
        block = "\n        ".join(missing)
        if "</queries>" in text:
            text = text.replace("</queries>", "    " + block + "\n    </queries>", 1)
        else:
            text = text.replace(
                "</manifest>",
                "    <queries>\n        " + block + "\n    </queries>\n</manifest>",
                1,
            )
    return text


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    with open(path, encoding="utf-8") as f:
        original = f.read()
    if "<application" not in original or "</manifest>" not in original:
        print("Unexpected manifest, nothing changed: " + path, file=sys.stderr)
        return 1
    patched = patch(original)
    with open(path, "w", encoding="utf-8") as f:
        f.write(patched)
    print("Patched " + path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
