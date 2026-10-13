import 'dart:async';

import 'package:almus_ai/security/app_lock_controller.dart';
import 'package:almus_ai/security/biometric_service.dart';
import 'package:almus_ai/security/lock_settings.dart';
import 'package:almus_ai/security/privacy_screen.dart';

const BiometricCapabilities strongBiometrics = BiometricCapabilities(
  deviceSupported: true,
  canCheckBiometrics: true,
  kinds: <BiometricKind>[BiometricKind.strong],
);

/// Device PIN only: no biometric enrolled.
const BiometricCapabilities credentialOnly = BiometricCapabilities(
  deviceSupported: true,
  canCheckBiometrics: false,
);

/// A scripted stand-in for Android's biometric prompt. No real biometrics are
/// involved in any automated test.
class FakeBiometricService implements BiometricService {
  FakeBiometricService({
    this.caps = strongBiometrics,
    List<AuthOutcome>? script,
  }) : script = script ?? <AuthOutcome>[];

  BiometricCapabilities caps;

  /// Answers handed out in order. When empty the fake answers `failed`.
  final List<AuthOutcome> script;

  /// When set, `authenticate` waits for this completer (to test timing).
  Completer<AuthOutcome>? hold;

  /// When set, `authenticate` throws it.
  Exception? throwOnAuth;

  int calls = 0;
  int cancelCalls = 0;
  final List<bool> credentialFlags = <bool>[];

  @override
  Future<BiometricCapabilities> capabilities() async => caps;

  @override
  Future<AuthOutcome> authenticate({
    required String reason,
    required bool allowDeviceCredential,
  }) async {
    calls++;
    credentialFlags.add(allowDeviceCredential);
    final Exception? error = throwOnAuth;
    if (error != null) throw error;
    final Completer<AuthOutcome>? pending = hold;
    if (pending != null) return pending.future;
    if (script.isEmpty) return AuthOutcome.failed;
    return script.removeAt(0);
  }

  @override
  Future<void> cancel() async => cancelCalls++;
}

class FakePrivacyScreen implements PrivacyScreen {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}

/// Controller with no animation delays, so tests run instantly.
AppLockController makeLockController(
  FakeBiometricService service, {
  MemoryLockSettingsStore? store,
  DateTime Function()? clock,
  PrivacyScreen? privacy,
}) {
  return AppLockController(
    service: service,
    store: store ?? MemoryLockSettingsStore(),
    privacy: privacy,
    clock: clock,
    initDuration: Duration.zero,
    scanDuration: Duration.zero,
    successHold: Duration.zero,
  );
}
