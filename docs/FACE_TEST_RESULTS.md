# Phase 6 test results (honest status)

| Suite | Status |
|---|---|
| Python patch scripts + calibration tool (`python3 -m unittest discover -s tool -p "test_*.py"`) | **Run here: 27 tests, all passed** |
| Backend (`npm test` in `Backend/`) | **Run here: 105 tests, all passed** (unchanged by this phase) |
| Dart/Flutter face tests (102 test cases in 8 files `test/face_*_test.dart`) | **NOT RUN.** No Flutter SDK or network exists in the sandbox. They run in GitHub Actions (`flutter test`). |
| `flutter analyze`, release APK build | **NOT RUN** (same reason). New plugins (`camera`, `flutter_secure_storage`, `audioplayers`, `image`) were never compiled. |
| Physical-device tests | **NOT RUN** (`FACE_DEVICE_TEST_PLAN.md`) |

The Dart tests cover: embedding normalisation/rejection, matcher (match,
unknown, ambiguity margin, uncalibrated, model mismatch), calibration refusal
and measured FAR, manifest validation, quality gate, alignment maths,
pipeline failures and picture deletion, encrypted vault (round trip, no
plaintext, tamper, key loss, crypto-erase), consent, legacy photo purge, model
locator checksum, scan-sound rules (opt-in, no overlap, 15 s cap, stop on
mute/background/cancel), recognition state machine (verified only after a
calibrated match), enrollment/re-enrollment/cancel/delete/withdraw, screen
states, and source-level no-logging/no-network rules.

**No accuracy figures exist** (FAR, FRR, speed, memory): no model was run.
Test "embeddings" are hand-made 4-number vectors that prove the code paths only.
