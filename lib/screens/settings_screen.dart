import 'package:flutter/material.dart';

import '../controllers/settings_controller.dart';
import '../models/app_settings.dart';
import '../services/backend_client.dart';
import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_info.dart';
import 'avatar_lab_screen.dart';
import '../widgets/glow_card.dart';
import '../widgets/screen_header.dart';

/// Settings: Gemini connection, theme preference, app info, about and privacy.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.settings,
    required this.backend,
  });

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
            'expressive animated avatar.',
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
