# Face recognition: anti-spoofing and presentation attacks (Phase 6)

**The app has no liveness detection and says so on screen.** Nothing in this
phase protects against someone holding up a photo or video.

## Options investigated

| Approach | Practical? | Why it is not enough / not done |
|---|---|---|
| Blink or head-turn challenge (ML Kit eye-open and head-angle values) | Easy to build | A replayed video of a person blinking or turning passes it. It is a usability gesture, not liveness. **Deliberately not implemented, to avoid a false claim.** |
| Passive texture/reflection classifier (a separate anti-spoof model) | Possible | Needs another model with its own verified licence and training-data terms (none verified), and its own calibration against the attacks that matter. Such models are known to generalise poorly across cameras and screens. |
| Flash / colour-challenge, multi-frame analysis | Possible | Unproven on this app's cameras; still beaten by a good replay on a bright screen. |
| Depth / infrared sensing | Only on specific hardware | Not accessible to a normal Flutter app. This is what certified phone face unlock uses. |
| Android `BiometricPrompt`, Class 3 (strong) | **Yes** | Already used for the app lock. Certified biometrics are tested against presentation attacks by the device maker; this app's custom recognition is not. |

Conclusion: custom face recognition here is a convenience feature only. For
anything security-sensitive use Android's biometric prompt or the device PIN.

## Known limitations (what to expect; none of this is measured)

| Situation | Expectation |
|---|---|
| Printed photograph | Likely accepted; nothing checks depth or texture. |
| Image shown on another phone/tablet screen | Likely accepted. |
| Replayed video | Likely accepted, including one with blinking. |
| Low, bright, backlit or uneven light | More false rejects; extreme light is rejected by a simple brightness gate (not a real quality metric). |
| Pose (turned, tilted head) | A gate rejects large angles (>20 deg yaw/pitch, >25 deg roll); smaller changes still change scores. |
| Different cameras (enrolled with one, scanned with another) | Scores can shift; the threshold was calibrated, if at all, on specific data only. |
| Similar-looking people, relatives, twins | Can score above the threshold. The margin rule only helps between *enrolled* people. |
| Glasses, beard, masks, make-up, ageing | Can cause misses or look-alike confusion. |
| Deepfakes / 3D masks | Out of scope; assume they work. |

Each row has a test in `FACE_DEVICE_TEST_PLAN.md`. Do not claim robustness
until those tests are done and recorded.
