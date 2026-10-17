# Face recognition: physical-device test plan (Phase 6)

None of this has been run. Automated tests use fake "embeddings" and prove
the logic only, not recognition quality. These tests need a real phone, a
real model (see `FACE_MODEL_LICENSING.md`) and real people who agreed.

Before starting, **write down the error rates you can accept** (for example
"at most 1 wrong accept in 100 impostor attempts"). Do not choose them after
seeing results.

How many attempts: with zero errors in n independent attempts, the true error
rate can still be as high as about 3/n (rule of three). To support "below 1%"
you need roughly 300 error-free impostor attempts; 30 attempts only support
"below 10%". Record counts, never just "worked".

Record sheet columns: tester, phone model, Android version, camera, light
(lux or description), pose, attempt number, expected (match/unknown), result
shown, state shown, notes.

## Tests

| # | Test | Steps | Pass condition |
|---|---|---|---|
| 1 | Consent | Open Face recognition, tap Enroll | Full consent text shown first; "No" captures nothing and stores nothing |
| 2 | Enrollment | Agree, enrol yourself in normal light | 3 pictures captured, "Enrolled", no picture left in cache (debug build: `adb shell run-as com.almus.almus_ai ls cache`) |
| 3 | Match | Scan yourself 30 times over several days | Count verified vs not; compare with your accepted false-reject rate |
| 4 | Unknown people | Scan at least 10 consenting people, many attempts each | No "IDENTITY VERIFIED"; state UNKNOWN IDENTITY |
| 5 | Look-alikes | Relatives/similar people, with consent | Record any false accept; any is a finding |
| 6 | Light | Dim room, window backlight, direct bright light, outdoors | Record rejects ("too dark/bright") and wrong results |
| 7 | Pose | Turn/tilt head by roughly 10, 20, 30 degrees | Large angles rejected; small ones recorded |
| 8 | Cameras | Enrol on phone A, scan on phone B (or after clearing and re-enrolling) | Record score behaviour; templates are per-phone |
| 9 | Accessories | Glasses on/off, hat, mask, beard changes | Record |
| 10 | Spoofing (own face only) | Printed photo, photo on another screen, replayed video of yourself | **Expected: accepted** (no liveness). Record it and keep the "no liveness" warning |
| 11 | Re-enrollment | Enrol the same name again | Old templates replaced; one entry |
| 12 | Cancel | Cancel during enrollment and during a scan | Old data intact, sound stops, no result shown |
| 13 | Deletion | Delete one person, then Delete all, then Withdraw consent | List empty; next scan says nobody enrolled; vault file gone |
| 14 | Sound | Turn sound on; scan; cancel; press Home mid-scan; mute mid-scan; let a scan time out | Starts with scan, stops at end/cancel/background/mute, never longer than 15 s, never doubled |
| 15 | Camera denied / missing | Deny camera permission | CAMERA UNAVAILABLE state; no sound |
| 16 | App lock | Keep the biometric lock on; use face screen | Lock behaviour unchanged; face match never unlocks anything |
| 17 | Legacy photo | Upgrade from Phase 9 build with a saved sample | Old JPEG removed after opening the screen |
| 18 | Performance | Time one scan; watch memory/heat over 20 scans | Record numbers; they are the only performance claims allowed |

## Calibration data

Collect scores for many same-person pairs (genuine) and different-person pairs
(impostor) on the model + preprocessing used by the app, save as CSV
`kind,score`, then:

    python3 tool/calibrate_threshold.py scores.csv --target-far 0.001 \
        --margin 0.05 --data-description "who/what/how many"

It refuses with too little data (at least 100 genuine pairs and 10/targetFAR
impostor pairs). Put the printed `calibration` block into `manifest.json`.
Measured rates describe only that data, not other people or cameras.
