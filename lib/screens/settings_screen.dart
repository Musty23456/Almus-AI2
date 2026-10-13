import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/settings_controller.dart';
import '../models/app_settings.dart';
import '../security/app_lock_controller.dart';
import '../services/backend_client.dart';
import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_info.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings.dart';
import '../voice/voice_settings_store.dart';
import 'avatar_lab_screen.dart';
import 'face_enrollment_screen.dart';
import '../widgets/glow_card.dart';
import '../widgets/screen_header.dart';
import '../widgets/security_settings_section.dart';

/// Settings: Gemini connection, theme preference, app info, about and privacy.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.settings,
    required this.backend,
    this.voiceSettings,
    this.voice,
    this.appLock,
  });

  /// Phase 7: biometric app lock. Null hides the Security section.
  final AppLockController? appLock;

  /// Phase 6: voice preferences. Null hides the Voice section.
  final VoiceSettingsController? voiceSettings;
  final VoiceController? voice;

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final SettingsController settings;
  final BackendClient backend;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.settings.value.backendUrl);
  late final TextEditingController _token =
      TextEditingController(text: widget.settings.value.accessToken);
  bool _showToken = false;
  bool _testing = false;
  String? _message;
  bool _messageIsError = false;
  int _versionTaps = 0;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _show(String text, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = isError;
    });
  }

  Future<void> _save() async {
    final String raw = _url.text.trim();
    if (raw.isEmpty) {
      _token.clear();
      await widget.settings.save(const AppSettings());
      _show('Backend cleared. Chat is in DEMO MODE.', isError: false);
      return;
    }
    final String? url = normalizeBackendUrl(raw);
    if (url == null) {
      _show(
        'Enter a valid https:// address, for example https://almus-backend.onrender.com',
        isError: true,
      );
      return;
    }
    final bool stored = await widget.settings.save(
      AppSettings(backendUrl: url, accessToken: _token.text.trim()),
    );
    _url.text = url;
    _show(
      stored
          ? 'Saved. Chat now uses your backend.'
          : 'Applied for this session, but it could not be stored on the device.',
      isError: !stored,
    );
  }

  Future<void> _test() async {
    final String? url = normalizeBackendUrl(_url.text);
    if (url == null) {
      _show('Enter a valid https:// backend address first.', isError: true);
      return;
    }
    setState(() => _testing = true);
    try {
      final ConnectionInfo info = await widget.backend.checkConnection(
        AppSettings(backendUrl: url, accessToken: _token.text.trim()),
      );
      _show('Connected. Backend model: ${info.model}.', isError: false);
    } on ChatServiceException catch (e) {
      _show(e.message, isError: true);
    } on Exception {
      _show('Connection test failed. Please try again.', isError: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Tapping the version 7 times unlocks the developer-only Avatar Lab.
  void _onVersionTap() {
    if (AvatarLabScreen.unlocked.value) return;
    _versionTaps++;
    if (_versionTaps >= 7) {
      AvatarLabScreen.unlocked.value = true;
      setState(() {});
      _show('Developer options unlocked: Avatar Lab.', isError: false);
    }
  }

  void _openAvatarLab() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AvatarLabScreen()),
    );
  }

  Widget _connectionCard(ThemeData theme) {
    final ColorScheme cs = theme.colorScheme;
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ValueListenableBuilder<AppSettings>(
            valueListenable: widget.settings,
            builder: (BuildContext context, AppSettings value, Widget? _) {
              return _InfoRow(
                icon: value.isConfigured
                    ? Icons.bolt_rounded
                    : Icons.science_outlined,
                title: 'Mode',
                value: value.isConfigured
                    ? 'LIVE (Gemini via backend)'
                    : 'DEMO MODE (simulated)',
              );
            },
          ),
          Divider(height: 24, color: cs.outlineVariant),
          TextField(
            key: const Key('backend_url_field'),
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Backend URL',
              hintText: 'https://your-backend.onrender.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('access_token_field'),
            controller: _token,
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Access token',
              helperText: 'The APP_ACCESS_TOKEN you set on the server',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showToken ? 'Hide token' : 'Show token',
                onPressed: () => setState(() => _showToken = !_showToken),
                icon: Icon(
                  _showToken ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  key: const Key('save_connection'),
                  onPressed: _testing ? null : _save,
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  key: const Key('test_connection'),
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test connection'),
                ),
              ),
            ],
          ),
          if (_message != null) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  _messageIsError
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 18,
                  color: _messageIsError ? cs.error : AlmusColors.mint,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _message!,
                    style: TextStyle(
                      color: _messageIsError ? cs.error : cs.onSurface,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Your Gemini API key is never entered here. It stays on your backend server. Leave the URL empty to use DEMO MODE.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceCard(ThemeData theme, VoiceSettingsController controller) {
    final ColorScheme cs = theme.colorScheme;
    return GlowCard(
      child: ValueListenableBuilder<VoiceSettings>(
        valueListenable: controller,
        builder: (BuildContext context, VoiceSettings v, Widget? _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SwitchListTile(
                key: const Key('auto_speak_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Read replies aloud automatically'),
                subtitle: const Text(
                  'Error messages are never read aloud. You can still tap the speaker under any reply.',
                ),
                value: v.autoSpeak,
                onChanged: (bool on) {
                  unawaited(controller.save(v.copyWith(autoSpeak: on)));
                  if (!on) unawaited(widget.voice?.stopSpeaking() ?? Future<void>.value());
                },
              ),
              SwitchListTile(
                key: const Key('auto_send_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Send voice messages automatically'),
                subtitle: const Text(
                  'Off: what you say appears in the message box so you can check it first.',
                ),
                value: v.autoSendVoice,
                onChanged: (bool on) =>
                    unawaited(controller.save(v.copyWith(autoSendVoice: on))),
              ),
              Divider(height: 20, color: cs.outlineVariant),
              const Text(
                'Voice language',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<VoiceLanguage>(
                  key: const Key('voice_language_selector'),
                  showSelectedIcon: false,
                  segments: <ButtonSegment<VoiceLanguage>>[
                    for (final VoiceLanguage l in VoiceLanguage.values)
                      ButtonSegment<VoiceLanguage>(
                        value: l,
                        label: Text(l.label),
                      ),
                  ],
                  selected: <VoiceLanguage>{v.language},
                  onSelectionChanged: (Set<VoiceLanguage> selection) => unawaited(
                    controller.save(v.copyWith(language: selection.first)),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Used for listening and for the reading voice. Hausa works only if your phone\'s speech engine has Hausa installed; many phones do not. If it is missing, Almus tells you instead of guessing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              Divider(height: 20, color: cs.outlineVariant),
              Text('Speech speed: ${v.speechRate.toStringAsFixed(2)}'),
              Slider(
                key: const Key('speech_rate_slider'),
                min: VoiceSettings.minRate,
                max: VoiceSettings.maxRate,
                divisions: 16,
                value: v.speechRate,
                onChanged: (double r) =>
                    controller.value = v.copyWith(speechRate: r),
                onChangeEnd: (double r) =>
                    unawaited(controller.save(controller.value)),
              ),
              Text('Volume: ${(v.volume * 100).round()}%'),
              Slider(
                key: const Key('speech_volume_slider'),
                min: 0,
                max: 1,
                divisions: 10,
                value: v.volume,
                onChanged: (double vol) =>
                    controller.value = v.copyWith(volume: vol),
                onChangeEnd: (double vol) =>
                    unawaited(controller.save(controller.value)),
              ),
              if (widget.voice != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('test_voice_button'),
                    onPressed: () => unawaited(
                      widget.voice!.speakText(
                        v.language == VoiceLanguage.hausa
                            ? 'Sannu, ni ne Almus. Ina jin ka.'
                            : 'Hello, I am Almus. This is how I sound.',
                      ),
                    ),
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('Test voice'),
                  ),
                ),
              if (widget.voice?.notice != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  widget.voice!.notice!,
                  style: TextStyle(color: cs.error, height: 1.4),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'The microphone opens only when you tap it and closes when you stop. The app never records or stores audio; Android\'s speech service turns it into text. Some engines send audio to Google for recognition.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? body = theme.textTheme.bodyMedium?.copyWith(height: 1.5);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: <Widget>[
        const ScreenHeader(
          title: 'Settings',
          subtitle: 'Preferences and information',
        ),
        const SectionLabel('Gemini connection'),
        _connectionCard(theme),
        if (widget.voiceSettings != null) ...<Widget>[
          const SectionLabel('Voice'),
          _voiceCard(theme, widget.voiceSettings!),
        ],
        if (widget.appLock != null) ...<Widget>[
          const SectionLabel('Security'),
          SecuritySettingsCard(controller: widget.appLock!),
        ],
        const SectionLabel('Face security · Phase 9'),
        GlowCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.face_retouching_natural)),
            title: const Text('Face detection & enrollment'),
            subtitle: const Text('Capture a private face sample on this device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const FaceEnrollmentScreen(),
              ),
            ),
          ),
        ),
        const SectionLabel('Appearance'),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Theme',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Applies while the app is open (not saved yet).',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('Light'),
                    ),
                  ],
                  selected: <ThemeMode>{widget.themeMode},
                  onSelectionChanged: (Set<ThemeMode> selection) =>
                      widget.onThemeModeChanged(selection.first),
                ),
              ),
            ],
          ),
        ),
        const SectionLabel('App information'),
        GlowCard(
          child: Column(
            children: <Widget>[
              InkWell(
                key: const Key('version_row'),
                onTap: _onVersionTap,
                child: const _InfoRow(
                  icon: Icons.tag,
                  title: 'Version',
                  value: AppInfo.version,
                ),
              ),
              Divider(height: 24, color: cs.outlineVariant),
              const _InfoRow(
                icon: Icons.build_outlined,
                title: 'Build',
                value: AppInfo.build,
              ),
              Divider(height: 24, color: cs.outlineVariant),
              const _InfoRow(
                icon: Icons.layers_outlined,
                title: 'Release',
                value: AppInfo.phase,
              ),
              Divider(height: 24, color: cs.outlineVariant),
              ValueListenableBuilder<AppSettings>(
                valueListenable: widget.settings,
                builder: (BuildContext context, AppSettings value, Widget? _) {
                  return _InfoRow(
                    icon: value.isConfigured
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    title: 'Gemini',
                    value: value.isConfigured
                        ? 'Backend configured'
                        : 'Not connected',
                  );
                },
              ),
            ],
          ),
        ),
        if (AvatarLabScreen.unlocked.value) ...<Widget>[
          const SectionLabel('Developer'),
          GlowCard(
            key: const Key('avatar_lab_tile'),
            onTap: _openAvatarLab,
            child: const _InfoRow(
              icon: Icons.science_outlined,
              title: 'Avatar Lab',
              value: 'Test every avatar state',
            ),
          ),
        ],
        const SectionLabel('About ALMUS AI'),
        GlowCard(
          child: Text(
            'ALMUS AI is a personal assistant built primarily for one user. '
            'It is planned to grow into a teacher, programming assistant, '
            'research assistant, adviser and conversational companion with '
            'long-term memory. Phase 2 added real Gemini answers through a '
            'backend that you deploy yourself (without one the app stays in '
            'DEMO MODE). Phase 3 saves your chats on this phone. Phase 4 adds '
            'personal memory that you control. Phase 5 gives the robot a more '
            'expressive animated avatar. Phase 6 adds voice input and spoken '
            'replies. Phase 7 adds a biometric lock that uses Android\'s own '
            'fingerprint / face prompt.',
            style: body,
          ),
        ),
        const SectionLabel('Privacy'),
        const GlowCard(
          child: Column(
            children: <Widget>[
              _BulletRow(
                'In DEMO MODE the app makes no network requests. In live mode it only contacts the backend address you enter.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'Live messages are sent to your backend and then to Google Gemini. On a free Gemini tier Google may use prompts to improve its products, so avoid sensitive details.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'Conversations are saved in a local database on this phone. Delete one chat from History, or use Clear all history to remove everything.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'Personal memories are also stored only on this phone. When memory is on and you use LIVE MODE, the few memories that match your message are sent with it to your backend and Google Gemini. Turn memory off in the Memory tab, or for a single chat in Chat.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'The Gemini API key is never stored in the app. Only the backend URL and your access token are kept in the phone\'s private app storage, separate from the chat database.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'Voice: the microphone opens only after you tap it, and a bar shows while it is on. Audio is never saved by the app. Android\'s speech service converts it to text, and some engines send audio to Google to do so. Spoken replies use your phone\'s text-to-speech engine.',
              ),
              SizedBox(height: 10),
              _BulletRow(
                'Security: the app lock uses Android\'s biometric prompt. The app never opens the camera for it and never receives or stores fingerprints, face data or iris data; Android only answers yes or no. Nothing about your biometrics is sent to Gemini or any server. The lock hides the app but does not encrypt the local database.',
              ),
              SizedBox(height: 10),
              _BulletRow('No account, analytics or advertising components are included.'),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _BulletRow extends StatelessWidget {
  const _BulletRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
        ),
      ],
    );
  }
}
