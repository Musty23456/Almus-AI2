import 'dart:async';

import 'package:flutter/material.dart';

import '../security/app_lock_controller.dart';
import '../security/biometric_service.dart';
import '../security/lock_settings.dart';
import '../theme/app_theme.dart';
import 'glow_card.dart';

/// Settings card for Android-native biometric / face authentication (Phase 8).
class SecuritySettingsCard extends StatefulWidget {
  const SecuritySettingsCard({super.key, required this.controller});

  final AppLockController controller;

  @override
  State<SecuritySettingsCard> createState() => _SecuritySettingsCardState();
}

class _SecuritySettingsCardState extends State<SecuritySettingsCard> {
  bool _working = false;
  String? _message;
  bool _messageIsError = false;

  void _show(String? text, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = isError;
    });
  }

  Future<void> _run(Future<LockChange> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final LockChange result = await action();
      _show(
        result.message ?? (result.ok ? 'Saved.' : 'Not changed.'),
        isError: !result.ok || result.message != null,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _test() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final BiometricCapabilities caps =
          await widget.controller.refreshCapabilities();
      _show(
        '${caps.describe()} Authentication is possible: '
        '${caps.deviceSupported ? 'yes' : 'no'}.',
        isError: !caps.deviceSupported,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? small = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      height: 1.4,
    );

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final AppLockController c = widget.controller;
        final LockSettings s = c.settings;
        final BiometricCapabilities caps = c.capabilities;
        final bool locked = _working || c.inProgress;

        return GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SwitchListTile(
                key: const Key('lock_enabled_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Require biometric unlock'),
                subtitle: const Text(
                  'Opens Android\'s fingerprint / face prompt every time the app starts or returns.',
                ),
                value: s.enabled,
                onChanged: locked
                    ? null
                    : (bool on) => unawaited(_run(() => c.setEnabled(on))),
              ),
              Divider(height: 20, color: cs.outlineVariant),
              const Text(
                'Available methods',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                caps.describe(),
                key: const Key('lock_methods_text'),
                style: TextStyle(color: cs.onSurface, height: 1.4),
              ),
              const SizedBox(height: 6),
              Text(
                'What is available depends on your phone and Android settings. '
                'Android only tells apps the strength class of a biometric, not '
                'whether it is a face or a finger on every device. If face is '
                'reported, Android may offer its enrolled face method; this app '
                'cannot force face-only authentication through the generic Flutter '
                'API. Some phones\' face unlock is weaker than fingerprint. To '
                'enrol or change a face/fingerprint, open Android Settings > '
                'Security (or Biometrics). This app never sees or stores biometric data.',
                style: small,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('lock_test_button'),
                onPressed: locked ? null : () => unawaited(_test()),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Test biometric availability'),
              ),
              Divider(height: 20, color: cs.outlineVariant),
              const Text(
                'Auto-lock',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              DropdownButton<AutoLockDelay>(
                key: const Key('auto_lock_dropdown'),
                isExpanded: true,
                value: s.autoLock,
                items: <DropdownMenuItem<AutoLockDelay>>[
                  for (final AutoLockDelay d in AutoLockDelay.values)
                    DropdownMenuItem<AutoLockDelay>(
                      value: d,
                      child: Text(d.label),
                    ),
                ],
                onChanged: locked || !s.enabled
                    ? null
                    : (AutoLockDelay? d) {
                        if (d != null) {
                          unawaited(_run(() => c.setAutoLock(d)));
                        }
                      },
              ),
              Text(
                'How long the app may stay in the background before it asks '
                'again. "Immediately" is the safest. A longer delay is '
                'convenient but lets someone who picks up your phone within '
                'that time open the app, so choosing a longer delay asks you '
                'to confirm first.',
                style: small,
              ),
              Divider(height: 20, color: cs.outlineVariant),
              SwitchListTile(
                key: const Key('lock_fallback_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow device PIN / pattern / password'),
                subtitle: const Text(
                  'This is your phone\'s own screen lock, checked by Android. The app has no PIN of its own.',
                ),
                value: s.allowDeviceCredential,
                onChanged: locked || !s.enabled
                    ? null
                    : (bool on) => unawaited(
                          _run(() => c.setAllowDeviceCredential(on)),
                        ),
              ),
              if (_working || c.inProgress) ...<Widget>[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_message != null) ...<Widget>[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      _messageIsError
                          ? Icons.info_outline
                          : Icons.check_circle_outline,
                      size: 18,
                      color: _messageIsError ? AlmusColors.amber : AlmusColors.mint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _message!,
                        key: const Key('lock_settings_message'),
                        style: TextStyle(color: cs.onSurface, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Turning the lock off needs you to confirm with Android first. '
                'The lock hides the app; it does not encrypt the chat '
                'database. While the lock is on, screenshots and the recent-apps '
                'preview are blocked.',
                style: small,
              ),
            ],
          ),
        );
      },
    );
  }
}
