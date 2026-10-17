import 'package:flutter/material.dart';

import '../controllers/settings_controller.dart';
import '../face/cloud/cloud_face_api.dart';
import '../face/cloud/cloud_face_controller.dart';
import '../face/cloud/cloud_face_production.dart';
import '../face/cloud/cloud_face_storage.dart';
import '../widgets/glow_card.dart';

/// Cloud 1:1 face verification (Luxand through your backend).
///
/// Unlike the on-device face screen this one UPLOADS photos, and says so
/// before anything is captured. It is not a lock: the app lock stays with
/// Android's biometric prompt.
class CloudFaceScreen extends StatefulWidget {
  const CloudFaceScreen({super.key, required this.settings, this.controller});

  final SettingsController settings;

  /// Supplied by tests; the app builds the real one.
  final CloudFaceController? controller;

  @override
  State<CloudFaceScreen> createState() => _CloudFaceScreenState();
}

class _CloudFaceScreenState extends State<CloudFaceScreen> with WidgetsBindingObserver {
  late final CloudFaceController _c;
  Future<void> Function()? _close;
  String? _backendNote;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      _c = widget.controller!;
    } else {
      final built = buildProductionCloudFace(() => widget.settings.value);
      _c = built.controller;
      _close = built.close;
    }
    _c.refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _c.onBackground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.dispose();
    _close?.call();
    super.dispose();
  }

  Future<bool> _ensureConsent() async {
    if (_c.hasConsent) return true;
    final bool? agreed = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text(kCloudFaceConsentTitle),
        content: const SingleChildScrollView(child: Text(kCloudFaceConsentText)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('NO, CANCEL'),
          ),
          FilledButton(
            key: const Key('cloud-consent-agree'),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('I AGREE'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return false;
    await _c.grantConsent();
    return true;
  }

  Future<void> _enrollFlow() async {
    if (!await _ensureConsent() || !mounted) return;
    final TextEditingController name = TextEditingController();
    final String? chosen = await showDialog<String>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Who is being enrolled?'),
        content: TextField(
          controller: name,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Name (replaces the current enrolled face)',
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('CANCEL')),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(name.text),
            child: const Text('START'),
          ),
        ],
      ),
    );
    name.dispose();
    if (chosen == null || !mounted) return;
    await _c.enroll(chosen);
  }

  Future<void> _verifyFlow() async {
    if (!await _ensureConsent() || !mounted) return;
    await _c.verify();
  }

  Future<bool> _confirm(String title, String text, String action) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(action)),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _checkBackend() async {
    String note;
    try {
      final CloudFaceStatus st = await _c.backendStatus();
      if (!st.available) {
        note = 'The backend has no Luxand token (or a wrong address) configured.';
      } else if (!st.calibrated) {
        note = 'Backend reachable, but no similarity threshold is set, so matching is off.';
      } else {
        note = 'Backend reachable and set up. This does not prove matching is accurate.';
      }
    } on CloudFaceException catch (e) {
      note = e.message;
    } on Object {
      note = 'The check failed. Please try again.';
    }
    if (mounted) setState(() => _backendNote = note);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud face verification')),
      body: ListenableBuilder(
        listenable: _c,
        builder: (BuildContext context, Widget? _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final CloudScanState s = _c.state;
    final Color accent = switch (s) {
      CloudScanState.verified => Colors.green,
      CloudScanState.notVerified => Colors.orange,
      CloudScanState.failed || CloudScanState.cameraUnavailable => cs.error,
      _ => cs.primary,
    };
    final bool enrolled = _c.link != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        GlowCard(
          glowColor: accent,
          child: Column(
            children: <Widget>[
              Text(
                cloudScanTitle(s),
                key: const Key('cloud-state-title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(_c.message, key: const Key('cloud-state-message'), textAlign: TextAlign.center),
              if (s == CloudScanState.verified && _c.verifiedName != null) ...<Widget>[
                const SizedBox(height: 8),
                Text('Matched: ${_c.verifiedName}',
                    key: const Key('cloud-verified-name'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Extra check only. It can be fooled by a photo or video and does not unlock anything.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_c.cameraOpen)
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(aspectRatio: 3 / 4, child: _c.capture.buildPreview()),
          ),
        const SizedBox(height: 12),
        if (_c.busy)
          OutlinedButton.icon(
            key: const Key('cloud-cancel'),
            onPressed: _c.cancel,
            icon: const Icon(Icons.close),
            label: const Text('CANCEL'),
          )
        else
          FilledButton.icon(
            key: const Key('cloud-verify'),
            onPressed: enrolled ? _verifyFlow : null,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('VERIFY (SENDS A PHOTO)'),
          ),
        const SizedBox(height: 12),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('ENROLLED PERSON', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              if (!enrolled)
                const Text('Nobody is enrolled.', key: Key('cloud-nobody'))
              else
                Text(_c.link!.name, key: const Key('cloud-enrolled-name')),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('cloud-enroll'),
                onPressed: _c.busy ? null : _enrollFlow,
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(enrolled ? 'RE-ENROLL (REPLACES)' : 'ENROLL ONE PERSON'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('cloud-delete'),
                onPressed: _c.busy
                    ? null
                    : () async {
                        final bool yes = await _confirm(
                          'Delete your face from the cloud?',
                          'The face is deleted at the service and then on this phone. '
                              'If the service cannot be reached, nothing is reported as deleted.',
                          'DELETE',
                        );
                        if (yes) await _c.deleteCloudFace();
                      },
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('DELETE MY FACE FROM THE CLOUD'),
              ),
              if (_c.hasConsent) ...<Widget>[
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('cloud-withdraw'),
                  onPressed: _c.busy
                      ? null
                      : () async {
                          final bool yes = await _confirm(
                            'Withdraw consent?',
                            'This deletes your face from the cloud service and this phone. '
                                'Consent is only cleared once the deletion succeeded.',
                            'WITHDRAW',
                          );
                          if (yes) await _c.withdrawConsent();
                        },
                  child: const Text('WITHDRAW CONSENT (DELETES DATA)'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('BACKEND', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('cloud-check-backend'),
                onPressed: _c.busy ? null : _checkBackend,
                child: const Text('CHECK BACKEND SETUP'),
              ),
              if (_backendNote != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(_backendNote!, key: const Key('cloud-backend-note')),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('LIMITS - PLEASE READ', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'This UPLOADS face photos (through your backend) to Luxand.cloud. '
                'The on-device face screen never uploads anything.\n\n'
                'It is not a lock. The app lock uses Android\'s biometric prompt and is unchanged.\n\n'
                'There is no proven liveness or anti-spoofing protection. A printed photo, a picture '
                'on another screen or a replayed video may be accepted. Poor light, look-alikes and '
                'different cameras can cause wrong or missed matches.\n\n'
                'The result is decided on this phone from the backend\'s answer, so a rooted or '
                'modified phone could fake it.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
