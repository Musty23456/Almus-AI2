# ALMUS AI - Phase 6b: optional cloud face verification (Luxand, 1:1)

## Outcome
The on-device face feature is unchanged (still no model, still never uploads). A second, separate option now exists:
1:1 verification through Luxand.cloud, via your backend, behind its own consent.

## Built
Backend (Node, **120/120 tests pass**, 15 new): `luxand.js`, routes in `app.js`, config, redaction, env/render/README.
App (Flutter, **not compiled or run**): `lib/face/cloud/*` (API client, secure link store, consent, controller, production wiring),
`lib/screens/cloud_face_screen.dart`, Settings entry; tests `cloud_face_*`, extended `face_privacy_static_test.dart`.

## Safety rules, and where they are tested
| Rule | Test |
|---|---|
| Token never in the app | static test (no luxand address in app code); backend tests |
| Fail closed on odd Luxand answer / no threshold | `luxand.test.js` |
| No consent -> nothing captured or sent | `cloud_face_controller_test.dart` |
| Only a single clear face is uploaded | same |
| "Deleted" only after the service confirmed | same + screen test |
| Cancel ignores a late "verified" | same |
| On-device code never imports cloud code, network only in one file | `face_privacy_static_test.dart` |

## Risks you must know
1. Dart not compiled: ~1,300 new lines. Send me the first red error from GitHub Actions.
2. `similarity` field and `DELETE /person/{uuid}` unverified against real Luxand (see docs/CLOUD_FACE_VERIFICATION.md).
3. No liveness. Do not treat it as a lock; keep Android biometric lock.
4. The app decides the final yes/no; a modified phone could fake it.
5. Luxand terms, price, retention and legal position unchecked.

## How to proceed
1. Rotate the Luxand token; set `LUXAND_API_TOKEN` on Render; deploy the Backend files.
2. Upload the project to GitHub; check the Actions build.
3. Calibrate and set `LUXAND_MIN_SIMILARITY`; do one real verify + one real delete.
