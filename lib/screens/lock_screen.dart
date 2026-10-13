import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../security/app_lock_controller.dart';
import '../security/biometric_service.dart';
import '../theme/app_theme.dart';
import '../widgets/biometric_eye_scanner.dart';
import '../widgets/gradient_text.dart';

/// Full-screen lock shown whenever private screens must stay hidden.
///
/// It is opaque and sits above the whole app (including dialogs). Whether the
/// user gets in is decided only by [AppLockController], which in turn only
/// believes Android's biometric prompt.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final AppLockController controller;

  /// Text shown under the eye for each state.
  static String statusLabel(AppLockState state) {
    return switch (state) {
      AppLockState.locked => 'SYSTEM LOCKED',
      AppLockState.initializing => 'INITIALIZING SECURE SCAN',
      AppLockState.scanning => 'SCANNING...',
      AppLockState.authenticating => 'WAITING FOR ANDROID SECURITY',
      AppLockState.verified => 'IDENTITY VERIFIED',
      AppLockState.failed => 'AUTHENTICATION FAILED',
      AppLockState.cancelled => 'AUTHENTICATION CANCELLED',
      AppLockState.unavailable => 'BIOMETRICS UNAVAILABLE',
      AppLockState.lockout => 'TEMPORARILY LOCKED OUT',
    };
  }

  static EyeScannerState scannerFor(AppLockState state) {
    return switch (state) {
      AppLockState.locked => EyeScannerState.locked,
      AppLockState.initializing => EyeScannerState.idle,
      AppLockState.scanning => EyeScannerState.scanning,
      AppLockState.authenticating => EyeScannerState.scanning,
      AppLockState.verified => EyeScannerState.verified,
      AppLockState.failed => EyeScannerState.failed,
      AppLockState.cancelled => EyeScannerState.locked,
      AppLockState.unavailable => EyeScannerState.locked,
      AppLockState.lockout => EyeScannerState.failed,
    };
  }

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  late AppLockState _last = widget.controller.state;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(LockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
      _last = widget.controller.state;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  /// Small vibration on success or failure (system haptics, no sound files).
  void _onChange() {
    final AppLockState now = widget.controller.state;
    if (now == _last) return;
    _last = now;
    if (now == AppLockState.verified) {
      unawaited(HapticFeedback.mediumImpact());
    } else if (now == AppLockState.failed || now == AppLockState.lockout) {
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  Color _statusColor(AppLockState s) {
    return switch (s) {
      AppLockState.verified => AlmusColors.mint,
      AppLockState.failed || AppLockState.lockout => AlmusColors.error,
      AppLockState.unavailable || AppLockState.cancelled => AlmusColors.amber,
      _ => AlmusColors.cyan,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final AppLockController c = widget.controller;
        final AppLockState s = c.state;
        final bool busy = s == AppLockState.initializing ||
            s == AppLockState.scanning ||
            s == AppLockState.authenticating ||
            s == AppLockState.verified;
        final bool unavailable = s == AppLockState.unavailable;
        final bool canTryBiometric = !unavailable || c.capabilities.deviceSupported;

        String primaryLabel = 'AUTHENTICATE';
        if (s == AppLockState.failed ||
            s == AppLockState.cancelled ||
            s == AppLockState.lockout) {
          primaryLabel = 'TRY AGAIN';
        }
        if (!c.capabilities.hasBiometrics && c.capabilities.deviceSupported) {
          primaryLabel = 'UNLOCK WITH DEVICE PIN';
        } else if (c.capabilities.hasBiometrics) {
          primaryLabel = 'AUTHENTICATE WITH ANDROID';
        }

        return Material(
          color: AlmusColors.background,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      GradientText(
                        'ALMUS AI SECURITY',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'BIOMETRIC ACCESS CONTROL',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 3,
                          color: AlmusColors.purple.withValues(alpha: 0.9),
                        ),
                      ),
                      const SizedBox(height: 24),
                      BiometricEyeScanner(
                        state: LockScreen.scannerFor(s),
                        maxSize: 280,
                        semanticLabel:
                            'Security scanner. ${LockScreen.statusLabel(s)}',
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: AlmusColors.surface.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: BiometricEyeScanner.colorFor(
                              LockScreen.scannerFor(s),
                            ).withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          c.capabilities.kinds.contains(BiometricKind.face)
                              ? 'ANDROID FACE BIOMETRIC • REPORTED'
                              : c.capabilities.hasBiometrics
                                  ? 'ANDROID BIOMETRIC • ENROLLED'
                                  : c.capabilities.deviceSupported
                                      ? 'DEVICE CREDENTIAL • AVAILABLE'
                                      : 'SECURE AUTHENTICATION UNAVAILABLE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        LockScreen.statusLabel(s),
                        key: const Key('lock_status'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          color: _statusColor(s),
                        ),
                      ),
                      if (c.message != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          c.message!,
                          key: const Key('lock_message'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (canTryBiometric)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const Key('lock_authenticate'),
                            onPressed: busy
                                ? null
                                : () => unawaited(c.authenticate()),
                            icon: busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    c.capabilities.kinds.contains(BiometricKind.face)
                                        ? Icons.face_retouching_natural
                                        : Icons.fingerprint,
                                  ),
                            label: Text(primaryLabel),
                          ),
                        ),
                      if (c.showFallbackButton &&
                          c.capabilities.hasBiometrics) ...<Widget>[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            key: const Key('lock_fallback'),
                            onPressed: busy
                                ? null
                                : () => unawaited(
                                      c.authenticate(useDeviceCredential: true),
                                    ),
                            icon: const Icon(Icons.pin_outlined),
                            label: const Text('USE DEVICE PIN / PATTERN'),
                          ),
                        ),
                      ],
                      if (c.showContinueWithoutLock) ...<Widget>[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            key: const Key('lock_continue_without'),
                            onPressed: () =>
                                unawaited(c.continueWithoutLock()),
                            child: const Text('CONTINUE WITHOUT LOCK'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Phase 8 uses Android\'s own biometric prompt. If '
                        'your phone reports and has enrolled face unlock, '
                        'Android may use it; otherwise it uses another enrolled '
                        'biometric or the permitted device PIN. This app does '
                        'not capture or match face images itself, and the eye '
                        'animation never grants access.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
