import 'dart:async';

import 'package:almus_ai/security/app_lock_controller.dart';
import 'package:almus_ai/security/biometric_service.dart';
import 'package:almus_ai/security/lock_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lock_fakes.dart';

void main() {
  group('unlocking', () {
    test('private content stays hidden until Android reports success',
        () async {
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.success]);
      final AppLockController c = makeLockController(fake);

      // Before settings are loaded the app counts as locked.
      expect(c.privateContentVisible, isFalse);

      await c.load();
      await pumpEventQueue();

      expect(fake.calls, 1);
      expect(fake.credentialFlags, <bool>[false]); // biometric only
      expect(c.state, LockState.verified);
      expect(c.isUnlocked, isTrue);
      expect(c.privateContentVisible, isTrue);
    });

    test('goes through the documented states in order', () async {
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.success]);
      final AppLockController c = makeLockController(fake);
      final List<LockState> seen = <LockState>[];
      c.addListener(() => seen.add(c.state));

      await c.load();
      await pumpEventQueue();

      expect(
        seen,
        containsAllInOrder(<LockState>[
          LockState.initializing,
          LockState.scanning,
          LockState.authenticating,
          LockState.verified,
        ]),
      );
    });

    test('failed authentication keeps the app locked and allows a retry',
        () async {
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.failed]);
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();

      expect(c.state, LockState.failed);
      expect(c.privateContentVisible, isFalse);
      expect(c.message, isNotNull);

      fake.script.add(AuthOutcome.success);
      await c.authenticate();
      await pumpEventQueue();

      expect(c.privateContentVisible, isTrue);
      expect(fake.calls, 2);
    });

    test('cancelling returns to a locked screen', () async {
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.cancelled]);
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();

      expect(c.state, LockState.cancelled);
      expect(c.privateContentVisible, isFalse);
    });

    test('an exception from the platform counts as not verified', () async {
      final FakeBiometricService fake = FakeBiometricService()
        ..throwOnAuth = Exception('boom');
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();

      expect(c.state, LockState.failed);
      expect(c.privateContentVisible, isFalse);
    });

    test('with the lock switched off the app opens without a prompt',
        () async {
      final FakeBiometricService fake = FakeBiometricService();
      final AppLockController c = makeLockController(
        fake,
        store: MemoryLockSettingsStore(const LockSettings(enabled: false)),
      );

      await c.load();
      await pumpEventQueue();

      expect(c.privateContentVisible, isTrue);
      expect(fake.calls, 0);
    });
  });

  group('unavailable and lockout', () {
    test('no biometric and no screen lock: explained, nothing is prompted',
        () async {
      final FakeBiometricService fake =
          FakeBiometricService(caps: BiometricCapabilities.none);
      final MemoryLockSettingsStore store = MemoryLockSettingsStore();
      final AppLockController c = makeLockController(fake, store: store);

      await c.load();
      await pumpEventQueue();

      expect(c.state, LockState.unavailable);
      expect(c.privateContentVisible, isFalse);
      expect(fake.calls, 0);
      expect(c.showContinueWithoutLock, isTrue);
      expect(c.showFallbackButton, isFalse);

      await c.continueWithoutLock();

      expect(c.privateContentVisible, isTrue);
      expect(store.settings.enabled, isFalse);
    });

    test('"not enrolled" from Android is shown as unavailable and stays locked',
        () async {
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.notEnrolled],
      );
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();

      expect(c.state, LockState.unavailable);
      expect(c.privateContentVisible, isFalse);
      // A screen lock exists, so there is no "continue without lock".
      expect(c.showContinueWithoutLock, isFalse);
    });

    test('temporary and permanent lockout are respected', () async {
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[
          AuthOutcome.lockedOut,
          AuthOutcome.permanentlyLockedOut,
        ],
      );
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();
      expect(c.state, LockState.lockout);
      expect(c.privateContentVisible, isFalse);
      expect(c.showFallbackButton, isTrue);

      await c.authenticate();
      await pumpEventQueue();
      expect(c.state, LockState.lockout);
      expect(c.privateContentVisible, isFalse);
      expect(c.message, contains('PIN'));
    });
  });

  group('fallback', () {
    test('the PIN fallback asks Android for device credentials', () async {
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.failed, AuthOutcome.success],
      );
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();
      expect(c.privateContentVisible, isFalse);

      await c.authenticate(useDeviceCredential: true);
      await pumpEventQueue();

      expect(fake.credentialFlags, <bool>[false, true]);
      expect(c.privateContentVisible, isTrue);
    });

    test('with no biometric enrolled the PIN is used directly', () async {
      final FakeBiometricService fake = FakeBiometricService(
        caps: credentialOnly,
        script: <AuthOutcome>[AuthOutcome.success],
      );
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();

      expect(fake.credentialFlags, <bool>[true]);
      expect(c.privateContentVisible, isTrue);
    });
  });

  group('auto-lock and lifecycle', () {
    Future<AppLockController> unlocked(
      FakeBiometricService fake, {
      MemoryLockSettingsStore? store,
      DateTime Function()? clock,
    }) async {
      final AppLockController c =
          makeLockController(fake, store: store, clock: clock);
      await c.load();
      await pumpEventQueue();
      expect(c.privateContentVisible, isTrue);
      return c;
    }

    test('immediate auto-lock hides the app at once and asks again on return',
        () async {
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.success, AuthOutcome.success],
      );
      final AppLockController c = await unlocked(fake);

      c.onLifecycle(AppLifecycleState.paused);
      expect(c.privateContentVisible, isFalse);

      c.onLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(fake.calls, 2);
      expect(c.privateContentVisible, isTrue);
    });

    test('the inactive state (system dialogs) does not lock', () async {
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.success]);
      final AppLockController c = await unlocked(fake);

      c.onLifecycle(AppLifecycleState.inactive);
      c.onLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(c.privateContentVisible, isTrue);
      expect(fake.calls, 1);
    });

    test('a delay keeps the app open for short trips and locks after it',
        () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.success, AuthOutcome.failed],
      );
      final AppLockController c = await unlocked(
        fake,
        store: MemoryLockSettingsStore(
          const LockSettings(autoLock: AutoLockDelay.after1Minute),
        ),
        clock: () => now,
      );

      // 30 seconds away: still unlocked.
      c.onLifecycle(AppLifecycleState.paused);
      expect(c.privateContentVisible, isTrue);
      now = now.add(const Duration(seconds: 30));
      c.onLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(c.privateContentVisible, isTrue);
      expect(fake.calls, 1);

      // 61 seconds away: locked, and Android is asked again.
      c.onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 61));
      c.onLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(fake.calls, 2);
      expect(c.privateContentVisible, isFalse);
    });

    test('a clock moved backwards locks the app', () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.success, AuthOutcome.failed],
      );
      final AppLockController c = await unlocked(
        fake,
        store: MemoryLockSettingsStore(
          const LockSettings(autoLock: AutoLockDelay.after5Minutes),
        ),
        clock: () => now,
      );

      c.onLifecycle(AppLifecycleState.paused);
      now = now.subtract(const Duration(minutes: 10));
      c.onLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(c.privateContentVisible, isFalse);
    });

    test('leaving the app while the prompt is open does not change the lock',
        () async {
      final FakeBiometricService fake = FakeBiometricService()
        ..hold = Completer<AuthOutcome>();
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();
      expect(c.state, LockState.authenticating);

      // The PIN screen or the prompt itself can push the app to background.
      c.onLifecycle(AppLifecycleState.paused);
      c.onLifecycle(AppLifecycleState.resumed);
      expect(fake.calls, 1); // no second prompt

      fake.hold!.complete(AuthOutcome.success);
      await pumpEventQueue();
      expect(c.privateContentVisible, isTrue);
    });

    test('a late answer after the app locked again is ignored', () async {
      final FakeBiometricService fake = FakeBiometricService()
        ..hold = Completer<AuthOutcome>();
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();
      expect(c.state, LockState.authenticating);

      c.lockNow();
      expect(fake.cancelCalls, 1);

      // The old prompt answers "success" too late.
      fake.hold!.complete(AuthOutcome.success);
      await pumpEventQueue();

      expect(c.isUnlocked, isFalse);
      expect(c.privateContentVisible, isFalse);
      expect(c.state, LockState.locked);
    });

    test('disposing during a prompt is safe', () async {
      final FakeBiometricService fake = FakeBiometricService()
        ..hold = Completer<AuthOutcome>();
      final AppLockController c = makeLockController(fake);

      await c.load();
      await pumpEventQueue();
      c.dispose();

      fake.hold!.complete(AuthOutcome.success);
      await pumpEventQueue();
      // Reaching this line without an exception is the assertion.
      expect(c.isUnlocked, isFalse);
    });
  });

  group('settings changes', () {
    Future<(AppLockController, FakeBiometricService, MemoryLockSettingsStore)>
        openApp({BiometricCapabilities caps = strongBiometrics}) async {
      final FakeBiometricService fake = FakeBiometricService(
        caps: caps,
        script: <AuthOutcome>[AuthOutcome.success],
      );
      final MemoryLockSettingsStore store = MemoryLockSettingsStore();
      final AppLockController c = makeLockController(fake, store: store);
      await c.load();
      await pumpEventQueue();
      expect(c.privateContentVisible, isTrue);
      return (c, fake, store);
    }

    test('turning the lock off needs Android to confirm first', () async {
      final (
        AppLockController c,
        FakeBiometricService fake,
        MemoryLockSettingsStore store
      ) = await openApp();

      fake.script.add(AuthOutcome.failed);
      LockChange result = await c.setEnabled(false);
      expect(result.ok, isFalse);
      expect(c.settings.enabled, isTrue);
      expect(store.settings.enabled, isTrue);

      fake.script.add(AuthOutcome.success);
      result = await c.setEnabled(false);
      expect(result.ok, isTrue);
      expect(c.settings.enabled, isFalse);
      expect(store.settings.enabled, isFalse);
    });

    test('turning the lock on is refused when the phone has no secure method',
        () async {
      final FakeBiometricService fake = FakeBiometricService(
        caps: BiometricCapabilities.none,
      );
      final AppLockController c = makeLockController(
        fake,
        store: MemoryLockSettingsStore(const LockSettings(enabled: false)),
      );
      await c.load();
      await pumpEventQueue();

      final LockChange result = await c.setEnabled(true);

      expect(result.ok, isFalse);
      expect(c.settings.enabled, isFalse);
    });

    test('a longer auto-lock needs confirmation, a shorter one does not',
        () async {
      final (
        AppLockController c,
        FakeBiometricService fake,
        MemoryLockSettingsStore store
      ) = await openApp();

      fake.script.add(AuthOutcome.failed);
      expect((await c.setAutoLock(AutoLockDelay.after5Minutes)).ok, isFalse);
      expect(c.settings.autoLock, AutoLockDelay.immediately);

      fake.script.add(AuthOutcome.success);
      expect((await c.setAutoLock(AutoLockDelay.after5Minutes)).ok, isTrue);
      expect(store.settings.autoLock, AutoLockDelay.after5Minutes);

      final int before = fake.calls;
      expect((await c.setAutoLock(AutoLockDelay.after15Seconds)).ok, isTrue);
      expect(fake.calls, before); // no prompt for a stricter setting
      expect(c.settings.autoLock, AutoLockDelay.after15Seconds);
    });

    test('the device PIN cannot be switched off when it is the only method',
        () async {
      final (
        AppLockController c,
        FakeBiometricService fake,
        MemoryLockSettingsStore store
      ) = await openApp(caps: credentialOnly);

      final LockChange result = await c.setAllowDeviceCredential(false);

      expect(result.ok, isFalse);
      expect(c.settings.allowDeviceCredential, isTrue);
      expect(store.settings.allowDeviceCredential, isTrue);
      expect(fake.calls, 1); // only the original unlock
    });

    test('hardware availability alone is not treated as enrolled biometrics', () {
      const BiometricCapabilities hardwareWithoutEnrollment =
          BiometricCapabilities(
        deviceSupported: true,
        canCheckBiometrics: true,
      );

      expect(hardwareWithoutEnrollment.canCheckBiometrics, isTrue);
      expect(hardwareWithoutEnrollment.hasBiometrics, isFalse);
    });

    test('refreshCapabilities reports what the phone says now', () async {
      final (
        AppLockController c,
        FakeBiometricService fake,
        MemoryLockSettingsStore _
      ) = await openApp();

      fake.caps = credentialOnly;
      final BiometricCapabilities caps = await c.refreshCapabilities();

      expect(caps.hasBiometrics, isFalse);
      expect(c.capabilities.deviceSupported, isTrue);
    });

    test('the privacy flag follows the lock setting', () async {
      final FakePrivacyScreen privacy = FakePrivacyScreen();
      final FakeBiometricService fake =
          FakeBiometricService(script: <AuthOutcome>[AuthOutcome.success]);
      final AppLockController c = makeLockController(fake, privacy: privacy);

      await c.load();
      await pumpEventQueue();
      expect(privacy.calls, <bool>[true]);

      fake.script.add(AuthOutcome.success);
      await c.setEnabled(false);
      expect(privacy.calls.last, isFalse);
    });
  });

  group('helpers', () {
    test('Android error codes map to outcomes', () {
      expect(outcomeForErrorCode('LockedOut'), AuthOutcome.lockedOut);
      expect(
        outcomeForErrorCode('PermanentlyLockedOut'),
        AuthOutcome.permanentlyLockedOut,
      );
      expect(outcomeForErrorCode('NotEnrolled'), AuthOutcome.notEnrolled);
      expect(outcomeForErrorCode('NotAvailable'), AuthOutcome.unavailable);
      expect(outcomeForErrorCode('PasscodeNotSet'), AuthOutcome.unavailable);
      expect(outcomeForErrorCode('UserCanceled'), AuthOutcome.cancelled);
      // Unknown codes are never treated as success.
      expect(outcomeForErrorCode('something_else'), AuthOutcome.error);
    });

    test('capabilities are described honestly', () {
      expect(
        BiometricCapabilities.none.describe(),
        contains('No biometric and no screen lock'),
      );
      expect(credentialOnly.describe(), contains('No biometric is enrolled'));
      expect(strongBiometrics.describe(), contains('Strong biometric'));
    });

    test('lock settings are stored and read back', () async {
      final MemoryLockSettingsStore store = MemoryLockSettingsStore();
      await store.save(
        const LockSettings(
          enabled: false,
          autoLock: AutoLockDelay.after1Minute,
          allowDeviceCredential: false,
        ),
      );
      final LockSettings s = await store.load();
      expect(s.enabled, isFalse);
      expect(s.autoLock, AutoLockDelay.after1Minute);
      expect(s.allowDeviceCredential, isFalse);
      // Unknown delay names fall back to the safest value.
      expect(AutoLockDelay.fromName('nonsense'), AutoLockDelay.immediately);
    });
  });
}
