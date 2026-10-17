#!/usr/bin/env python3
"""Tests for the Android patch scripts. Run: python3 -m unittest discover -s tool -p "test_*.py" """
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MANIFEST = """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="almus_ai"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true">
        </activity>
    </application>
    <queries>
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT"/>
            <data android:mimeType="text/plain"/>
        </intent>
    </queries>
</manifest>
"""

STYLES = """<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">
    </style>
</resources>
"""


class ManifestPatchTest(unittest.TestCase):
    def setUp(self):
        self.m = load("patch_android_manifest")

    def test_adds_microphone_queries_and_disables_backup(self):
        out = self.m.patch(MANIFEST)
        self.assertIn("android.permission.RECORD_AUDIO", out)
        self.assertIn("android.speech.RecognitionService", out)
        self.assertIn("android.intent.action.TTS_SERVICE", out)
        self.assertIn('android:allowBackup="false"', out)
        # Existing query is kept and only one <queries> block exists.
        self.assertIn("PROCESS_TEXT", out)
        self.assertEqual(out.count("<queries>"), 1)

    def test_adds_camera_permission_as_optional_feature(self):
        out = self.m.patch(MANIFEST)
        self.assertIn("android.permission.CAMERA", out)
        self.assertIn('android:name="android.hardware.camera" android:required="false"', out)
        self.assertEqual(out.count("android.permission.CAMERA"), 1)

    def test_is_idempotent(self):
        once = self.m.patch(MANIFEST)
        self.assertEqual(self.m.patch(once), once)
        self.assertEqual(once.count("RECORD_AUDIO"), 1)
        self.assertEqual(once.count("allowBackup"), 1)

    def test_overrides_an_existing_allow_backup_true(self):
        text = MANIFEST.replace("<application", '<application android:allowBackup="true"', 1)
        out = self.m.patch(text)
        self.assertIn('android:allowBackup="false"', out)
        self.assertNotIn('android:allowBackup="true"', out)

    def test_backup_change_can_be_disabled(self):
        self.m.ALLOW_BACKUP = None
        self.assertNotIn("allowBackup", self.m.patch(MANIFEST))

    def test_creates_queries_block_when_missing(self):
        text = MANIFEST.split("    <queries>")[0] + "</manifest>\n"
        out = self.m.patch(text)
        self.assertEqual(out.count("<queries>"), 1)
        self.assertIn("TTS_SERVICE", out)


class BiometricPatchTest(unittest.TestCase):
    def setUp(self):
        self.b = load("patch_android_biometric")

    def test_manifest_permission_added_once(self):
        once = self.b.patch_manifest(MANIFEST)
        self.assertIn("android.permission.USE_BIOMETRIC", once)
        self.assertEqual(self.b.patch_manifest(once), once)

    def test_styles_use_appcompat_parent(self):
        out = self.b.patch_styles(STYLES)
        self.assertEqual(out.count("Theme.AppCompat.DayNight.NoActionBar"), 2)
        self.assertEqual(self.b.patch_styles(out), out)

    def test_main_activity_keeps_package_and_extends_fragment_activity(self):
        src = self.b.main_activity_source("package com.almus.almus_ai\n\nclass MainActivity")
        self.assertTrue(src.startswith("package com.almus.almus_ai"))
        self.assertIn("FlutterFragmentActivity", src)
        self.assertIn("almus.ai/privacy", src)

    def test_main_activity_requires_package_line(self):
        with self.assertRaises(ValueError):
            self.b.main_activity_source("class MainActivity")


if __name__ == "__main__":
    unittest.main()


class CameraQueryTests(unittest.TestCase):
    """Phase 3: the camera app must be visible to the app on Android 11+."""

    def test_image_capture_query_added_once(self):
        import patch_android_manifest as pm
        base = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                '<application android:label="x"></application></manifest>')
        once = pm.patch(base)
        twice = pm.patch(once)
        self.assertIn("android.media.action.IMAGE_CAPTURE", once)
        self.assertEqual(once, twice)
        self.assertEqual(twice.count("android.media.action.IMAGE_CAPTURE"), 1)
        self.assertIn("android.speech.RecognitionService", twice)
        self.assertIn("RECORD_AUDIO", twice)
