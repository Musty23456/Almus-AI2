# ALMUS AI - Phase 6: Face recognition with privacy and security controls

## Outcome in one paragraph

No face-recognition model could be verified as safely licensed, so **no model
is bundled and the app does not recognise anyone yet**. Instead this phase
delivers everything around a model, built so that fake recognition is
impossible: a refusal to match without a checksummed, calibrated model,
encrypted template storage, consent, deletion, scan states, scan sound,
honest limits, tests and documentation. This is the blocker path the brief
asked for, not a silent downgrade.

## What was found (initial assessment)

* The old screen (Phase 9) ran ML Kit **detection** and saved a plain JPEG of
  your face. Detection does not identify anyone. That screen is removed and
  the stored JPEG is deleted automatically.
* Model licensing, runtime and security limits: `docs/FACE_MODEL_LICENSING.md`.
  Key finding (verified from InsightFace's own pages): its pretrained
  recognition models are non-commercial research only. Other candidates could
  not be verified and are excluded.

## Requirement by requirement

| Brief | Status |
|---|---|
| 1 Assessment | Done; no model chosen (blocker documented, alternatives given) |
| 2 Pipeline | Built: front camera stills, ML Kit detection, quality gate, eye-based alignment, embedding interface, enrollment (3 samples), matching, unknown rejection, re-enrollment, deletion. **Embedding step has no model**, so it reports "unavailable" |
| 2 Calibrated thresholds | Required by design: no built-in default; `tool/calibrate_threshold.py` refuses small data |
| 3 Privacy | Consent (versioned), encrypted vault (AES-256-GCM, Keystore-backed key), pictures deleted, no upload, no logging, reliable delete (file + key). `docs/FACE_PRIVACY.md` |
| 4 Anti-spoofing | Investigated; **none implemented, none claimed**; limits documented. `docs/FACE_ANTI_SPOOFING.md` |
| 5 Scan sound | Original synthesized loop, off by default, mute switch, starts when a scan starts, stops on end/cancel/background/mute, 15 s hard cap, no overlap, never affects results |
| 6 UI states | Ready, Scanning, Face detected, Matching, Identity verified, Unknown identity, Recognition failed, Camera unavailable (+ Recognition unavailable). Name shown only in the verified state |
| 7 Auth safety | App lock untouched; face feature is extra; a test checks face code does not import the lock |
| 8 Testing | 102 Dart test cases + 5 Python written; Dart not run here; device plan written; no accuracy numbers |

## Files

New: `lib/face/*` (15 files), `lib/screens/face_recognition_screen.dart`,
`assets/audio/scan_loop.wav` (+README), `tool/calibrate_threshold.py` (+test),
`test/face_*` (9 files), docs listed above.
Changed: `pubspec.yaml` (v0.13.0+13; new deps `camera`, `flutter_secure_storage`,
`audioplayers`, `image`), `tool/patch_android_manifest.py` (CAMERA permission,
camera optional), Settings entry.
Removed: `lib/screens/face_enrollment_screen.dart`.

## Risks you must know

1. **Nothing in Flutter was compiled or run here.** The four new plugins and
   ~2,500 lines of Dart are untested until GitHub Actions runs. If the build
   fails, send me the first red error and I will fix it.
2. Chosen defaults: scanning sound off until enabled; 3 enrollment samples;
   12 s scan timeout; result shown 8 s. Easy to change.
3. Camera stills may make the system shutter sound on some phones.

## How to proceed

1. Upload the ZIP contents to GitHub as before; check the Actions build.
2. To get real recognition, follow "Binding a model" in
   `docs/FACE_MODEL_LICENSING.md` after choosing a model whose licence and
   training-data terms you can document (for example by obtaining a licence
   from the model authors), then run the device plan.
3. For security, keep using Android's biometric lock.
