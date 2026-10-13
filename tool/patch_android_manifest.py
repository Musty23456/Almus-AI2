#!/usr/bin/env python3
"""Adds the Android declarations that Phase 6 voice needs to AndroidManifest.xml.

Run after `flutter create` (the CI workflow does this). Safe to run twice.

  - RECORD_AUDIO permission: the microphone, requested at run time only when
    the user taps the microphone button.
  - <queries> entries: on Android 11+ the app must declare that it talks to a
    speech-recognition service and a text-to-speech engine, otherwise the
    system hides them and voice reports "not available".

Usage: python3 tool/patch_android_manifest.py [path/to/AndroidManifest.xml]
"""
import re
import sys

DEFAULT = "android/app/src/main/AndroidManifest.xml"

PERMISSIONS = [
    '<uses-permission android:name="android.permission.RECORD_AUDIO"/>',
]

QUERY_INTENTS = {
    "android.speech.RecognitionService":
        '<intent>\n            <action android:name="android.speech.RecognitionService"/>\n        </intent>',
    "android.intent.action.TTS_SERVICE":
        '<intent>\n            <action android:name="android.intent.action.TTS_SERVICE"/>\n        </intent>',
}


def patch(text: str) -> str:
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
