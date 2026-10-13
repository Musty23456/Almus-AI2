import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import 'biometric_service.dart';
import 'lock_settings.dart';
import 'privacy_screen.dart';

/// What the lock screen is doing right now.
enum AppLockState {
  /// Waiting for the user to authenticate.
  locked,

  /// Short start-up animation before the Android prompt.
  initializing,

  /// Eye animation while the Android prompt is being opened.
  scanning,

  /// Android's prompt is open; waiting for its real answer.
  authenticating,

  /// Android confirmed the user (shown briefly, then the app opens).
  verified,

  /// Android did not confirm the user. The app stays locked.
  failed,

  /// The user cancelled. The app stays locked.
  cancelled,

  /// This phone cannot authenticate (no biometric and no screen lock).
  unavailable,

  /// Android blocked biometrics after too many wrong attempts.
  lockout,
}

/// Outcome of a change made from Settings.
class LockChange {
  const LockChange.ok([this.message]) : ok = true;
  const LockChange.refused(this.message) : ok = false;

  final bool ok;
  final String? message;
}

/// Decides whether private screens may be shown.
///
/// Rules this class enforces:
///  * Private content is visible only after Android reports a successful
///    authentication in this session (or the lock is switched off).
///  * Until settings are loaded the app is treated as locked.
///  * An answer that arrives after the app was locked again, or after a newer
///    attempt started, is ignored (see [_isCurrent]).
///  * Any exception counts as "not verified".
///  * The app locks again after being in the background longer than the
///    chosen delay. Nothing here ever opens the camera or stores biometrics.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required BiometricService service,
    required LockSettingsStore store,
    PrivacyScreen? privacy,
    DateTime Function()? clock,
    this.initDuration = const Duration(milliseconds: 300),
    this.scanDuration = const Duration(milliseconds: 500),
    this.successHold = const Duration(milliseconds: 800),
  })  : _service = service,
        _store = store,
        _privacy = privacy,
        _clock = clock ?? DateTime.now;

  final BiometricService _service;
  final LockSettingsStore _store;
  final PrivacyScreen? _privacy;
  final DateTime Function() _clock;

  /// Lengths of the animation phases that come before Android's prompt.
  /// They are short and fixed: they are decoration, never a "scan".
  final Duration initDuration;
  final Duration scanDuration;

  /// How long "IDENTITY VERIFIED" is shown before the app opens.
  final Duration successHold;

  LockSettings _settings = const LockSettings();
  BiometricCapabilities _caps = BiometricCapabilities.none;
  AppLockState _state = AppLockState.initializing;
  String? _message;

  bool _loaded = false;
  bool _loading = false;
  bool _unlocked = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _promptedThisLock = false;

  /// An unlock attempt is in progress.
  bool _busy = false;

  /// A "confirm it is you" prompt for a settings change is in progress.
  bool _confirming = false;

  /// Bumped whenever the app locks or a new attempt starts, so answers from
  /// older attempts can be recognised and dropped.
  int _attempt = 0;

  DateTime? _backgroundedAt;

  LockSettings get settings => _settings;
  BiometricCapabilities get capabilities => _caps;
  AppLockState get state => _state;
  String? get message => _message;
  bool get loaded => _loaded;
  bool get isUnlocked => _unlocked;

  /// True while a prompt is open (lock screen or Settings confirmation).
  bool get inProgress => _busy || _confirming;

  /// The only gate for private screens (chat, memory, history, settings).
  bool get privateContentVisible =>
      _loaded && (!_settings.enabled || _unlocked);

  /// Show the "use PIN / pattern" button.
  bool get showFallbackButton {
    if (!_caps.deviceSupported) return false;
    if (_state == AppLockState.lockout) return true;
    // With no biometric enrolled the PIN is the only way in, so offer it
    // even if the preference is off (otherwise the user would be locked out).
    return _settings.allowDeviceCredential || !_caps.hasBiometrics;
  }

  /// Only when the phone has no secure method at all can the user choose to
  /// continue without a lock (there is nothing to protect the data anyway).
  bool get showContinueWithoutLock =>
      _state == AppLockState.unavailable && !_caps.deviceSupported;

  // ---------------------------------------------------------------- loading

  Future<void> load() async {
    if (_loaded || _loading || _disposed) return;
    _loading = true;
    _setState(AppLockState.initializing);
    try {
      _settings = await _store.load();
    } on Exception {
      // Could not read preferences: stay with the safe defaults (lock on).
      _settings = const LockSettings();
    }
    await _refreshCapabilities();
    _loading = false;
    _loaded = true;
    _applyPrivacy();
    if (_settings.enabled) {
      _lock();
      if (!_caps.deviceSupported) {
        _setUnavailable();
      } else {
        _autoPrompt();
      }
    } else {
      _unlocked = true;
      _notify();
    }
  }

  Future<void> _refreshCapabilities() async {
    try {
      _caps = await _service.capabilities();
    } on Exception {
      _caps = BiometricCapabilities.none;
    }
  }

  /// Re-reads what the phone supports (used by "Test biometric availability").
  Future<BiometricCapabilities> refreshCapabilities() async {
    await _refreshCapabilities();
    _notify();
    return _caps;
  }

  void _applyPrivacy() {
    final PrivacyScreen? privacy = _privacy;
    if (privacy == null) return;
    unawaited(privacy.setSecure(_settings.enabled));
  }

  // -------------------------------------------------------------- lifecycle

  /// Called by the lock gate for every Android lifecycle change.
  void onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _onResume();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _onBackground();
      case AppLifecycleState.inactive:
        // Also happens for system dialogs and the biometric prompt itself.
        break;
    }
  }

  void _onBackground() {
    if (!_loaded || !_settings.enabled) return;
    // The device-credential screen and the biometric prompt can push the app
    // to the background; that must not lock or unlock anything by itself.
    if (inProgress) return;
    if (_unlocked) {
      _backgroundedAt = _clock();
      if (_settings.autoLock == AutoLockDelay.immediately) {
        _lock();
      }
    }
  }

  void _onResume() {
    final DateTime? since = _backgroundedAt;
    _backgroundedAt = null;
    if (_loaded && _settings.enabled && _unlocked && since != null) {
      final Duration away = _clock().difference(since);
      // A negative value means the clock was moved back: lock to be safe.
      if (away.isNegative || away >= _settings.autoLock.duration) {
        _lock();
      }
    }
    _autoPrompt();
  }

  // ------------------------------------------------------------- locking

  /// Locks the app now and invalidates any attempt that is still running.
  void lockNow() {
    if (!_loaded || !_settings.enabled) return;
    _lock();
  }

  void _lock() {
    final bool wasBusy = _busy || _confirming;
    _attempt++;
    _busy = false;
    _confirming = false;
    _unlocked = false;
    _promptedThisLock = false;
    _message = null;
    _state = _caps.deviceSupported ? AppLockState.locked : AppLockState.unavailable;
    if (wasBusy) unawaited(_service.cancel());
    _notify();
  }

  void _autoPrompt() {
    if (!_loaded || _unlocked || !_settings.enabled) return;
    if (_promptedThisLock || !_foreground || inProgress) return;
    if (_state != AppLockState.locked) return;
    _promptedThisLock = true;
    unawaited(authenticate());
  }

  bool _isCurrent(int token) =>
      !_disposed &&
      token == _attempt &&
      _loaded &&
      _settings.enabled &&
      !_unlocked;

  // ------------------------------------------------------ unlock attempts

  /// Starts an unlock attempt. [useDeviceCredential] lets the user pick the
  /// phone's PIN/pattern/password instead of (or as well as) a biometric.
  Future<void> authenticate({bool useDeviceCredential = false}) async {
    if (!_loaded || _unlocked || !_settings.enabled || inProgress) return;
    _busy = true;
    _promptedThisLock = true;
    final int token = ++_attempt;
    try {
      _message = null;
      _setState(AppLockState.initializing);
      await _pause(initDuration);
      if (!_isCurrent(token)) return;

      await _refreshCapabilities();
      if (!_isCurrent(token)) return;
      if (!_caps.deviceSupported) {
        _setUnavailable();
        return;
      }

      final bool credential = useDeviceCredential || !_caps.hasBiometrics;
      _setState(AppLockState.scanning);
      await _pause(scanDuration);
      if (!_isCurrent(token)) return;

      _setState(AppLockState.authenticating);
      AuthOutcome outcome;
      try {
        // A normal attempt asks for a biometric only. The PIN/pattern is
        // allowed only when the user pressed the fallback button, or when no
        // biometric is enrolled (then it is the only possible method).
        outcome = await _service.authenticate(
          reason: 'Unlock ALMUS AI',
          allowDeviceCredential: credential,
        );
      } on Exception {
        outcome = AuthOutcome.error;
      }
      // Stale answer (locked again or newer attempt): drop it.
      if (!_isCurrent(token)) return;

      await _handleOutcome(outcome, token);
    } finally {
      if (token == _attempt) _busy = false;
    }
  }

  Future<void> _handleOutcome(AuthOutcome outcome, int token) async {
    switch (outcome) {
      case AuthOutcome.success:
        _message = null;
        _setState(AppLockState.verified);
        await _pause(successHold);
        if (!_isCurrent(token)) return;
        _unlocked = true;
        _backgroundedAt = null;
        _notify();
      case AuthOutcome.failed:
        _message = 'Android did not confirm your identity. You can try again.';
        _setState(AppLockState.failed);
      case AuthOutcome.cancelled:
        _message = 'Authentication was cancelled. The app stays locked.';
        _setState(AppLockState.cancelled);
      case AuthOutcome.notEnrolled:
        await _refreshCapabilities();
        if (!_isCurrent(token)) return;
        _message = 'No biometric is enrolled on this phone. Add one in '
            'Android Settings > Security, or use your device PIN.';
        _setState(AppLockState.unavailable);
      case AuthOutcome.unavailable:
        await _refreshCapabilities();
        if (!_isCurrent(token)) return;
        _setUnavailable();
      case AuthOutcome.lockedOut:
        _message = 'Too many wrong attempts. Android has paused biometrics '
            'for a short time. Wait a little, or use your device PIN.';
        _setState(AppLockState.lockout);
      case AuthOutcome.permanentlyLockedOut:
        _message = 'Biometrics are blocked until you unlock the phone with '
            'its PIN, pattern or password. Use your device PIN below.';
        _setState(AppLockState.lockout);
      case AuthOutcome.error:
        _message = 'Something went wrong while talking to Android security. '
            'The app stays locked. Please try again.';
        _setState(AppLockState.failed);
    }
  }

  void _setUnavailable() {
    _message = 'This phone has no fingerprint, face or screen lock set up, '
        'so the app cannot be protected. Add a screen lock in Android '
        'Settings > Security, then come back.';
    _setState(AppLockState.unavailable);
  }

  /// Offered only when the phone has no secure method at all.
  Future<void> continueWithoutLock() async {
    if (!_loaded || !showContinueWithoutLock) return;
    _settings = _settings.copyWith(enabled: false);
    _unlocked = true;
    _attempt++;
    _applyPrivacy();
    _notify();
    await _save();
  }

  // ------------------------------------------------------ settings changes

  /// Asks Android to confirm the user before a sensitive settings change.
  Future<bool> confirmIdentity({
    String reason = 'Confirm it is you to change security settings',
  }) async {
    if (!_loaded || inProgress || _disposed) return false;
    _confirming = true;
    try {
      await _refreshCapabilities();
      if (!_caps.deviceSupported) return false;
      final AuthOutcome outcome = await _service.authenticate(
        reason: reason,
        allowDeviceCredential:
            !_caps.hasBiometrics || _settings.allowDeviceCredential,
      );
      return outcome == AuthOutcome.success && !_disposed;
    } on Exception {
      return false;
    } finally {
      _confirming = false;
    }
  }

  Future<LockChange> setEnabled(bool on) async {
    if (!_loaded) return const LockChange.refused('Please wait a moment.');
    if (on == _settings.enabled) return const LockChange.ok();
    if (on) {
      await _refreshCapabilities();
      if (!_caps.deviceSupported) {
        return const LockChange.refused(
          'Set up a fingerprint, face unlock or screen lock in Android '
          'Settings > Security first, then switch this on.',
        );
      }
      if (!await confirmIdentity(
        reason: 'Confirm it is you to turn on the app lock',
      )) {
        return const LockChange.refused(
          'Identity was not confirmed, so the app lock was not changed.',
        );
      }
      _settings = _settings.copyWith(enabled: true);
    } else {
      // With no secure method at all there is nothing to confirm with.
      if (_caps.deviceSupported &&
          !await confirmIdentity(
            reason: 'Confirm it is you to turn off the app lock',
          )) {
        return const LockChange.refused(
          'Identity was not confirmed, so the app lock stays on.',
        );
      }
      _settings = _settings.copyWith(enabled: false);
      _unlocked = true;
    }
    _applyPrivacy();
    _notify();
    return _saved(await _save());
  }

  Future<LockChange> setAutoLock(AutoLockDelay delay) async {
    if (!_loaded) return const LockChange.refused('Please wait a moment.');
    if (delay == _settings.autoLock) return const LockChange.ok();
    // A longer delay makes the app easier to open, so it needs confirmation.
    if (_settings.enabled && delay.duration > _settings.autoLock.duration) {
      if (!await confirmIdentity(
        reason: 'Confirm it is you to make the auto-lock longer',
      )) {
        return const LockChange.refused(
          'Identity was not confirmed, so auto-lock was not changed.',
        );
      }
    }
    _settings = _settings.copyWith(autoLock: delay);
    _notify();
    return _saved(await _save());
  }

  Future<LockChange> setAllowDeviceCredential(bool on) async {
    if (!_loaded) return const LockChange.refused('Please wait a moment.');
    if (on == _settings.allowDeviceCredential) return const LockChange.ok();
    if (!on && _settings.enabled && !_caps.hasBiometrics) {
      return const LockChange.refused(
        'No biometric is enrolled, so the device PIN is currently the only '
        'way to unlock. It cannot be turned off.',
      );
    }
    if (on &&
        _settings.enabled &&
        !await confirmIdentity(
          reason: 'Confirm it is you to allow the device PIN',
        )) {
      return const LockChange.refused(
        'Identity was not confirmed, so this was not changed.',
      );
    }
    _settings = _settings.copyWith(allowDeviceCredential: on);
    _notify();
    return _saved(await _save());
  }

  LockChange _saved(bool stored) => stored
      ? const LockChange.ok()
      : const LockChange.ok(
          'Applied for now, but it could not be stored on this phone.',
        );

  Future<bool> _save() async {
    try {
      await _store.save(_settings);
      return true;
    } on Exception {
      return false;
    }
  }

  // --------------------------------------------------------------- helpers

  Future<void> _pause(Duration d) =>
      d == Duration.zero ? Future<void>.value() : Future<void>.delayed(d);

  void _setState(AppLockState s) {
    _state = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
