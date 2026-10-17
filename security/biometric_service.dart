import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Result of one request to Android's own biometric prompt.
///
/// The app never decides by itself that someone is who they claim to be: the
/// only way to [success] is for the operating system to say so.
enum AuthOutcome {
  /// Android confirmed the user (biometric, or device PIN/pattern/password
  /// when that was allowed for this request).
  success,

  /// The prompt ended without a confirmed identity (wrong biometric, prompt
  /// dismissed, or the app left the foreground). The `local_auth` plugin
  /// reports all of these as a plain "false", so they cannot be told apart.
  failed,

  /// The OS explicitly reported that the user cancelled.
  cancelled,

  /// The phone has no usable secure method (no biometrics and no screen lock).
  unavailable,

  /// Biometric hardware exists but nothing is enrolled.
  notEnrolled,

  /// Too many wrong attempts; Android blocks biometrics for a short time.
  lockedOut,

  /// Biometrics are blocked until the user unlocks with PIN/pattern/password.
  permanentlyLockedOut,

  /// Anything unexpected (treated as "not verified", never as success).
  error,
}

/// Kinds of biometric strength/type that the plugin may report.
///
/// Modern Android only reports a *class* (strong or weak) to apps, not
/// whether the enrolled biometric is a face, a fingerprint or an iris. The
/// face/fingerprint/iris values exist because some plugin versions and
/// devices still report them.
enum BiometricKind {
  strong('Strong biometric (Class 3)'),
  weak('Weak biometric (Class 2)'),
  face('Face (as reported by the phone)'),
  fingerprint('Fingerprint (as reported by the phone)'),
  iris('Iris (as reported by the phone)');

  const BiometricKind(this.label);

  final String label;
}

/// What the phone says it can do right now.
class BiometricCapabilities {
  const BiometricCapabilities({
    required this.deviceSupported,
    required this.canCheckBiometrics,
    this.kinds = const <BiometricKind>[],
  });

  /// Nothing usable at all (used when the platform cannot be queried).
  static const BiometricCapabilities none = BiometricCapabilities(
    deviceSupported: false,
    canCheckBiometrics: false,
  );

  /// True if Android can authenticate the user in any supported way
  /// (an enrolled biometric or a device PIN/pattern/password).
  final bool deviceSupported;

  /// True if biometric hardware is available to check. This does not
  /// necessarily mean that a biometric has been enrolled on the device.
  final bool canCheckBiometrics;

  /// Biometric categories reported by the phone.
  final List<BiometricKind> kinds;

  /// Whether Android reports at least one enrolled biometric.
  /// `canCheckBiometrics` alone only indicates hardware capability on some
  /// devices, so it must not be used to hide the PIN/pattern fallback.
  bool get hasBiometrics => kinds.isNotEmpty;

  String describe() {
    if (!deviceSupported && !hasBiometrics) {
      return 'No biometric and no screen lock are set up on this phone.';
    }
    if (!hasBiometrics) {
      return 'No biometric is enrolled. Only the device PIN, pattern or '
          'password can unlock the app.';
    }
    final String list = kinds.isEmpty
        ? 'A biometric is enrolled (Android did not report its type).'
        : 'Reported: ${kinds.map((BiometricKind k) => k.label).join(', ')}.';
    return list;
  }
}

/// Everything the app needs from the operating system's biometric system.
/// Tests replace this with a fake; nothing else in the app talks to Android.
abstract class BiometricService {
  Future<BiometricCapabilities> capabilities();

  /// Shows Android's own prompt. With [allowDeviceCredential] false only a
  /// biometric is accepted; with true the user may also use the device
  /// PIN/pattern/password.
  Future<AuthOutcome> authenticate({
    required String reason,
    required bool allowDeviceCredential,
  });

  /// Dismisses a prompt that is currently showing, if any.
  Future<void> cancel();
}

/// Maps a `PlatformException` code from `local_auth` to an [AuthOutcome].
/// Public for testing.
AuthOutcome outcomeForErrorCode(String code) {
  switch (code.toLowerCase()) {
    case 'lockedout':
      return AuthOutcome.lockedOut;
    case 'permanentlylockedout':
      return AuthOutcome.permanentlyLockedOut;
    case 'notenrolled':
      return AuthOutcome.notEnrolled;
    case 'notavailable':
    case 'passcodenotset':
      return AuthOutcome.unavailable;
    case 'usercanceled':
    case 'usercancelled':
    case 'systemcanceled':
      return AuthOutcome.cancelled;
    default:
      return AuthOutcome.error;
  }
}

/// The real implementation, backed by the `local_auth` plugin, which uses
/// Android's BiometricPrompt. No camera access, no images and no biometric
/// data ever reach this app: Android only answers yes or no.
class LocalAuthBiometricService implements BiometricService {
  LocalAuthBiometricService([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricCapabilities> capabilities() async {
    bool supported = false;
    bool canCheck = false;
    final List<BiometricKind> kinds = <BiometricKind>[];
    try {
      supported = await _auth.isDeviceSupported();
    } on PlatformException {
      supported = false;
    }
    try {
      canCheck = await _auth.canCheckBiometrics;
    } on PlatformException {
      canCheck = false;
    }
    try {
      final List<BiometricType> types = await _auth.getAvailableBiometrics();
      for (final BiometricType t in types) {
        final BiometricKind? kind = _kindFor(t);
        if (kind != null && !kinds.contains(kind)) kinds.add(kind);
      }
    } on PlatformException {
      // Leave the list empty.
    }
    return BiometricCapabilities(
      deviceSupported: supported || canCheck,
      canCheckBiometrics: canCheck,
      kinds: kinds,
    );
  }

  static BiometricKind? _kindFor(BiometricType type) {
    switch (type) {
      case BiometricType.strong:
        return BiometricKind.strong;
      case BiometricType.weak:
        return BiometricKind.weak;
      case BiometricType.face:
        return BiometricKind.face;
      case BiometricType.fingerprint:
        return BiometricKind.fingerprint;
      case BiometricType.iris:
        return BiometricKind.iris;
    }
  }

  @override
  Future<AuthOutcome> authenticate({
    required String reason,
    required bool allowDeviceCredential,
  }) async {
    try {
      final bool ok = await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: !allowDeviceCredential,
          // If the app leaves the foreground the attempt ends (not resumed).
          stickyAuth: false,
          sensitiveTransaction: true,
          useErrorDialogs: true,
        ),
      );
      return ok ? AuthOutcome.success : AuthOutcome.failed;
    } on PlatformException catch (e) {
      return outcomeForErrorCode(e.code);
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _auth.stopAuthentication();
    } on PlatformException {
      // Nothing to stop.
    }
  }
}
