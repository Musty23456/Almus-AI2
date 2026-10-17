import 'package:flutter/material.dart';

import '../face/face_consent.dart';
import '../face/face_dependencies.dart';
import '../face/face_enrollment_controller.dart';
import '../face/face_matcher.dart';
import '../face/face_model_locator.dart';
import '../face/face_recognition_controller.dart';
import '../widgets/glow_card.dart';

/// Face recognition (extra feature, NOT an authentication method).
///
/// The app lock stays with Android's own biometric prompt. This screen
/// recognises enrolled people on this phone only, and says so.
class FaceRecognitionScreen extends StatefulWidget {
  const FaceRecognitionScreen({super.key, this.dependencies});

  /// Supplied by tests; the app builds the real ones.
  final FaceDependencies? dependencies;

  @override
  State<FaceRecognitionScreen> createState() => _FaceRecognitionScreenState();
}

class _FaceRecognitionScreenState extends State<FaceRecognitionScreen>
    with WidgetsBindingObserver {
  FaceDependencies? _deps;
  FaceRecognitionController? _recognition;
  FaceEnrollmentController? _enrollment;
  bool _ownsDeps = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    final FaceDependencies deps =
        widget.dependencies ?? await FaceDependencies.production();
    _ownsDeps = widget.dependencies == null;
    if (!mounted) {
      if (_ownsDeps) await deps.dispose();
      return;
    }
    final FaceRecognitionController r = FaceRecognitionController(
      runtime: deps.runtime,
      capture: deps.capture,
      decoder: deps.decoder,
      detector: deps.detector,
      vault: deps.vault,
      sound: deps.sound,
    );
    final FaceEnrollmentController e = FaceEnrollmentController(
      runtime: deps.runtime,
      capture: deps.capture,
      decoder: deps.decoder,
      detector: deps.detector,
      vault: deps.vault,
      consentStore: deps.consentStore,
      sound: deps.sound,
    );
    setState(() {
      _deps = deps;
      _recognition = r;
      _enrollment = e;
    });
    await e.refresh();
    await r.prepare();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final FaceDependencies? d = _deps;
    final FaceRecognitionController? r = _recognition;
    if (d == null || r == null) return;
    d.sound.onLifecycle(state);
    if (state == AppLifecycleState.resumed) {
      r.onForeground();
    } else {
      r.onBackground();
      _enrollment?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recognition?.dispose();
    _enrollment?.dispose();
    if (_ownsDeps) _deps?.dispose();
    super.dispose();
  }

  Future<void> _enrollFlow() async {
    final FaceEnrollmentController e = _enrollment!;
    if (!e.hasConsent) {
      final bool? agreed = await showDialog<bool>(
        context: context,
        builder: (BuildContext c) => AlertDialog(
          title: const Text(kFaceConsentTitle),
          content: const SingleChildScrollView(child: Text(kFaceConsentText)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('NO, CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('I AGREE'),
            ),
          ],
        ),
      );
      if (agreed != true || !mounted) return;
      await e.grantConsent();
    }
    if (!mounted) return;
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
            hintText: 'Name (an existing name is re-enrolled)',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(name.text),
            child: const Text('START'),
          ),
        ],
      ),
    );
    name.dispose();
    if (chosen == null || !mounted) return;
    await _recognition!.onBackground(); // frees the camera for enrollment
    await e.enroll(chosen);
    if (mounted) await _recognition!.prepare();
  }

  Future<void> _confirmDeleteAll() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Delete all face data?'),
        content: const Text(
          'Every enrolled face template and its encryption key will be '
          'removed from this phone. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (yes == true) await _enrollment!.deleteAll();
  }

  Future<void> _confirmWithdraw() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Withdraw consent?'),
        content: const Text(
          'This deletes all face data now. Enrolling again will ask for '
          'consent again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('WITHDRAW'),
          ),
        ],
      ),
    );
    if (yes == true) await _enrollment!.withdrawConsent();
  }

  @override
  Widget build(BuildContext context) {
    final FaceRecognitionController? r = _recognition;
    final FaceEnrollmentController? e = _enrollment;
    final FaceDependencies? d = _deps;
    return Scaffold(
      appBar: AppBar(title: const Text('Face recognition')),
      body: (r == null || e == null || d == null)
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[r, e, d.sound]),
              builder: (BuildContext context, Widget? _) =>
                  _body(context, r, e, d),
            ),
    );
  }

  Widget _body(
    BuildContext context,
    FaceRecognitionController r,
    FaceEnrollmentController e,
    FaceDependencies d,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final ScanState s = r.state;
    final Color accent = switch (s) {
      ScanState.verified => Colors.green,
      ScanState.unknown => Colors.orange,
      ScanState.failed ||
      ScanState.cameraUnavailable ||
      ScanState.modelUnavailable =>
        cs.error,
      _ => cs.primary,
    };
    final bool canScan = !r.isBusy &&
        !e.busy &&
        s != ScanState.modelUnavailable &&
        s != ScanState.cameraUnavailable;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        GlowCard(
          glowColor: accent,
          child: Column(
            children: <Widget>[
              Text(
                scanStateTitle(s),
                key: const Key('scan-state-title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                r.message,
                key: const Key('scan-state-message'),
                textAlign: TextAlign.center,
              ),
              if (s == ScanState.verified && r.verifiedName != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Matched: ${r.verifiedName}',
                  key: const Key('verified-name'),
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Convenience match only. Not a security check, and it can '
                  'be fooled by a photo or video.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (r.cameraOpen)
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: d.capture.buildPreview(),
            ),
          ),
        const SizedBox(height: 12),
        if (r.isBusy)
          OutlinedButton.icon(
            key: const Key('cancel-scan'),
            onPressed: r.cancel,
            icon: const Icon(Icons.close),
            label: const Text('CANCEL SCAN'),
          )
        else
          FilledButton.icon(
            key: const Key('start-scan'),
            onPressed: canScan ? r.scan : null,
            icon: const Icon(Icons.radar),
            label: const Text('SCAN'),
          ),
        if (s == ScanState.cameraUnavailable) ...<Widget>[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: r.prepare,
            child: const Text('TRY CAMERA AGAIN'),
          ),
        ],
        const SizedBox(height: 16),
        GlowCard(
          child: SwitchListTile(
            key: const Key('scan-sound-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Scanning sound'),
            subtitle: const Text(
              'A short electronic loop while a scan runs. Feedback only: it '
              'says nothing about the result. Off by default.',
            ),
            value: d.sound.enabled,
            onChanged: (bool v) => d.sound.setEnabled(v),
          ),
        ),
        const SizedBox(height: 12),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('ENROLLED FACES',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              if (e.vaultUnreadable)
                const Text(
                  'Saved face data cannot be read. Delete it and enrol again.',
                  key: Key('vault-unreadable'),
                ),
              if (e.identities.isEmpty && !e.vaultUnreadable)
                const Text('Nobody is enrolled.', key: Key('nobody-enrolled')),
              for (final EnrolledIdentity id in e.identities)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(id.displayName),
                  subtitle: Text('${id.samples.length} templates'),
                  trailing: IconButton(
                    tooltip: 'Delete this person',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: e.busy ? null : () => e.deleteIdentity(id.id),
                  ),
                ),
              if (e.state != EnrollState.idle && e.message.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(e.message, key: const Key('enroll-message')),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('enroll-button'),
                onPressed:
                    (e.busy || r.isBusy || !r.runtime.usable) ? null : _enrollFlow,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('ENROLL A PERSON'),
              ),
              if (e.busy) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: e.cancel,
                  child: const Text('CANCEL ENROLLMENT'),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('delete-all'),
                onPressed: e.busy ? null : _confirmDeleteAll,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('DELETE ALL FACE DATA'),
              ),
              if (e.hasConsent) ...<Widget>[
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('withdraw-consent'),
                  onPressed: e.busy ? null : _confirmWithdraw,
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
              const Text('LIMITS - PLEASE READ',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'This is not a lock. The app lock uses Android\'s biometric '
                'prompt and is unchanged.\n\n'
                'There is NO liveness or anti-spoofing protection. A printed '
                'photo, a picture on another screen or a replayed video may '
                'be accepted. Look-alikes, poor light, different poses and '
                'different cameras can cause wrong or missed matches.\n\n'
                'Camera pictures are deleted right after processing. '
                'Templates stay encrypted on this phone and are never '
                'uploaded.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
