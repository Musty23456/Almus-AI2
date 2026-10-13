#!/usr/bin/env python3
"""Android changes that Phase 7 (biometric app lock) needs. Safe to run twice.

Run after `flutter create` (the CI workflow does this):

    python3 tool/patch_android_biometric.py

What it changes inside the generated `android/` folder:

  1. AndroidManifest.xml  - adds the USE_BIOMETRIC permission.
  2. MainActivity.kt      - extends FlutterFragmentActivity (required by the
                            local_auth plugin to show Android's biometric
                            prompt) and adds a tiny channel that switches
                            Android's FLAG_SECURE on/off. FLAG_SECURE blocks
                            screenshots and hides the app preview in the
                            recent-apps list while the lock is enabled.
  3. res/values*/styles.xml - the launch/normal themes inherit from an
                            AppCompat theme (also required by local_auth).

The script stops with an error (exit code 1) if the generated files do not
look as expected, so the build fails loudly instead of producing an app whose
lock silently does not work.
"""
import glob
import re
import sys

ANDROID = "android"
MANIFEST = ANDROID + "/app/src/main/AndroidManifest.xml"
PERMISSION = '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>'
APPCOMPAT_PARENT = "Theme.AppCompat.DayNight.NoActionBar"

KOTLIN_BODY = """import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth needs a FragmentActivity to show Android's biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the app turn FLAG_SECURE on or off (no screenshots and no
        // recent-apps preview while the app lock is enabled).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "almus.ai/privacy")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val secure = call.argument<Boolean>("secure") ?: true
                    runOnUiThread {
                        if (secure) {
                            window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE
                            )
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
"""


def patch_manifest(text: str) -> str:
    if "android.permission.USE_BIOMETRIC" in text:
        return text
    if "<application" not in text:
        raise ValueError("AndroidManifest.xml has no <application> element")
    return text.replace("<application", PERMISSION + "\n    <application", 1)


def patch_styles(text: str) -> str:
    # Point both app themes at an AppCompat parent (idempotent).
    def repl(match):
        return match.group(1) + APPCOMPAT_PARENT + match.group(3)

    return re.sub(
        r'(<style\s+name="(?:LaunchTheme|NormalTheme)"\s+parent=")([^"]*)(")',
        repl,
        text,
    )


def main_activity_source(existing: str) -> str:
    match = re.search(r"^\s*package\s+([\w.]+)", existing, re.MULTILINE)
    if not match:
        raise ValueError("MainActivity.kt has no package line")
    return "package " + match.group(1) + "\n\n" + KOTLIN_BODY


def main() -> int:
    try:
        with open(MANIFEST, encoding="utf-8") as f:
            manifest = f.read()
        with open(MANIFEST, "w", encoding="utf-8") as f:
            f.write(patch_manifest(manifest))
        print("Patched " + MANIFEST)

        activities = glob.glob(ANDROID + "/app/src/main/**/MainActivity.kt", recursive=True)
        if len(activities) != 1:
            raise ValueError("expected exactly one MainActivity.kt, found %d" % len(activities))
        with open(activities[0], encoding="utf-8") as f:
            existing = f.read()
        with open(activities[0], "w", encoding="utf-8") as f:
            f.write(main_activity_source(existing))
        print("Patched " + activities[0])

        styles = glob.glob(ANDROID + "/app/src/main/res/values*/styles.xml")
        if not styles:
            raise ValueError("no styles.xml found")
        for path in styles:
            with open(path, encoding="utf-8") as f:
                before = f.read()
            with open(path, "w", encoding="utf-8") as f:
                f.write(patch_styles(before))
            print("Patched " + path)
    except (OSError, ValueError) as error:
        print("Phase 7 Android patch failed: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
