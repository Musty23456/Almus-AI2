# ALMUS AI — Phase 7 security architecture

## Principle
Android decides who the user is. The app only asks and obeys. There is no custom face or iris matching, no camera access and no biometric data in the app.

## Pieces (all new files are under `lib/security/`, plus widgets/screens)
| File | Role |
|---|---|
| `security/biometric_service.dart` | `BiometricService` interface and the real `LocalAuthBiometricService` (plugin `local_auth` -> Android BiometricPrompt). Maps Android answers to `AuthOutcome`. |
| `security/app_lock_controller.dart` | State machine and policy: `privateContentVisible`, attempts, stale-answer protection, auto-lock, settings changes that need confirmation. |
| `security/lock_settings.dart` | Switches and delay stored in app preferences (no secrets). Defaults: lock on, immediate, PIN allowed. |
| `security/privacy_screen.dart` | Turns Android FLAG_SECURE on/off through a method channel. |
| `widgets/biometric_eye_scanner.dart` | Decorative animated eye (`idle/scanning/verified/failed/locked`). Never grants access. |
| `screens/lock_screen.dart` | The lock UI. |
| `widgets/app_lock_gate.dart` | Wraps the whole navigator; hides private screens; forwards lifecycle events. |
| `widgets/security_settings_section.dart` | Settings > Security card. |
| `tool/patch_android_biometric.py` | Android manifest, activity and theme changes. |

## Rules enforced by `AppLockController`
1. Locked until proven otherwise: before settings load the app is locked; `privateContentVisible` is true only if the lock is off or Android reported success in this session.
2. Fail closed: an exception, an unknown error code or "false" means not verified.
3. Stale answers: every lock or new attempt bumps a counter; an answer for an older attempt is ignored, and the open prompt is cancelled when the app locks.
4. Lifecycle: backgrounding is ignored while a prompt is open (the PIN screen and the prompt itself can background the app). `inactive` never locks. With "Immediately" the app locks when it is hidden/paused; with a delay it compares elapsed wall-clock time on return and locks if the clock moved backwards. After a process restart the app is always locked.
5. Settings: disabling the lock, a longer auto-lock and enabling the PIN fallback require Android confirmation; the PIN fallback cannot be switched off while it is the only enrolled method; the lock cannot be enabled on a phone with no secure method. "Continue without lock" appears only on such a phone.
6. No logging of authentication details; messages never contain personal data.

## Known security limitations
- The lock hides the UI only. The local SQLite database is not encrypted.
- `local_auth` decides which biometric class its prompt accepts; weak (Class 2) face unlock may be accepted on some phones. A strict "Class 3 only" policy would need native BiometricPrompt code.
- `local_auth` cannot distinguish a user cancel from a failed match on Android.
- The recent-apps preview and screenshots are blocked through FLAG_SECURE only while the lock is enabled; screen-reading accessibility services and a rooted device can still see content once unlocked.
- Auto-lock timing uses the wall clock (Android does not give apps a monotonic background timer here). Moving the clock backwards locks; moving it forwards only locks sooner.
- Everything here is verified by automated tests with a fake biometric service. It has not been verified on real hardware.

## Possible next steps
Encrypted database with a Keystore-held key; native strong-only biometric prompt; per-chat lock; panic lock.
