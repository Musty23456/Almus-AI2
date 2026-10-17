import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/provider_info.dart';
import '../ai/provider_status_controller.dart';
import '../ai/routing_preferences.dart';
import '../controllers/settings_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/glow_card.dart';

/// Phase 4: choose the AI provider, its model and the automatic-fallback rules, and see what is local and what is remote.
///
/// Honesty rules: a provider is never called "working" unless the backend really contacted it
/// (the "Check connections" button), and fallback is off until the user turns it on.
class AiProvidersScreen extends StatefulWidget {
  const AiProvidersScreen({
    super.key,
    required this.settings,
    required this.status,
    required this.routing,
  });

  final SettingsController settings;
  final ProviderStatusController status;
  final RoutingPreferencesController routing;

  @override
  State<AiProvidersScreen> createState() => _AiProvidersScreenState();
}

class _AiProvidersScreenState extends State<AiProvidersScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.status.refresh());
  }

  RoutingPreferences get _prefs => widget.routing.value;

  Future<void> _save(RoutingPreferences next) async {
    final bool stored = await widget.routing.update(next);
    if (!stored && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Applied for now, but could not be saved on this phone.')),
      );
    }
  }

  String _mainProviderId(ProvidersSnapshot? snap) =>
      _prefs.preferredProvider ?? snap?.primaryDefault ?? '';

  Future<void> _chooseModel(ProviderInfo provider) async {
    final Future<List<ProviderModel>> pending = widget.status.loadModels(provider.id);
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _ModelSheet(
        provider: provider,
        status: widget.status,
        selected: _prefs.models[provider.id],
        pending: pending,
      ),
    );
    if (picked == null) return;
    final Map<String, String> models = Map<String, String>.of(_prefs.models);
    if (picked == _ModelSheet.useDefault) {
      models.remove(provider.id);
    } else {
      models[provider.id] = picked;
    }
    await _save(_prefs.copyWith(models: models));
  }

  Widget _whereProcessed(ThemeData theme) {
    final ColorScheme cs = theme.colorScheme;
    final bool live = widget.settings.value.isConfigured;
    final TextStyle? small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.4);
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(live ? Icons.cloud_outlined : Icons.phone_android, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  live ? 'AI answers are processed remotely' : 'DEMO MODE: everything stays on this phone',
                  key: const Key('processing_title'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            live
                ? 'When you chat, your message is sent to your backend and from there to the provider listed below. '
                    'The providers are separate companies with their own data rules.'
                : 'No backend address is saved, so no message is sent anywhere and replies are scripted. '
                    'Add your backend in Settings to use a real AI provider.',
            style: small,
          ),
          const SizedBox(height: 10),
          const Text('Always local (these never need an AI provider):', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Opening and searching saved conversations · Reading and editing memory · Backup export and import · '
            'Reading attached documents (text is extracted on this phone) · App settings and lock',
            key: const Key('local_features_text'),
            style: small,
          ),
        ],
      ),
    );
  }

  Widget _providerCard(ThemeData theme, ProviderInfo p, ProvidersSnapshot snap) {
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.4);
    final String chosen = _prefs.models[p.id] ?? '';
    final String modelText = chosen.isNotEmpty
        ? 'Model: $chosen (your choice)'
        : (p.model != null
            ? 'Model: ${p.model}${p.modelSource == 'auto' ? ' (picked automatically)' : ''}'
            : 'Model: none selected yet');
    final String cost = switch (p.costPolicy) {
      'free_only' => 'Free models only (as declared by your server)',
      'metered' => 'May charge money (as declared by your server)',
      _ => 'Cost not declared: could be free or paid',
    };
    final bool good = p.state == ProviderState.healthy && p.verified;
    final Color stateColor = good
        ? AlmusColors.mint
        : (p.state == ProviderState.misconfigured || p.state == ProviderState.unavailable
            ? cs.error
            : cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlowCard(
        key: Key('provider_card_${p.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                const Chip(
                  label: Text('REMOTE'),
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.cloud_outlined, size: 16),
                ),
              ],
            ),
            Text(
              describeProviderState(p),
              key: Key('provider_status_${p.id}'),
              style: TextStyle(color: stateColor, fontWeight: FontWeight.w600),
            ),
            if (p.configured) ...<Widget>[
              const SizedBox(height: 8),
              Text(modelText, key: Key('provider_model_${p.id}')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: Key('choose_model_${p.id}'),
                  onPressed: () => _chooseModel(p),
                  child: const Text('Choose model'),
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  const _CapChip('Text'),
                  if (p.capabilities.extractedTextAttachments) const _CapChip('File text'),
                  _CapChip(p.capabilities.images ? 'Images' : 'No images'),
                  if (p.capabilities.maxInputTokens != null)
                    _CapChip('~${p.capabilities.maxInputTokens} input tokens max'),
                ],
              ),
              const SizedBox(height: 8),
              Text(cost, key: Key('provider_cost_${p.id}'), style: small),
              if (p.dataNote.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(p.dataNote, style: small),
              ],
              if (p.limitsNote.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(p.limitsNote, style: small),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: Key('check_${p.id}'),
                  onPressed: widget.status.isChecking ? null : () => widget.status.checkOne(p.id),
                  child: const Text('Check this provider'),
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Add its key on your backend server to use it. See docs/PROVIDERS.md.',
                  style: small,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mainProviderCard(ThemeData theme, ProvidersSnapshot snap) {
    final List<ProviderInfo> usable = snap.providers.where((ProviderInfo p) => p.configured).toList();
    final String mainId = _mainProviderId(snap);
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Main provider', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Answers every message unless you allow fallback below.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              ChoiceChip(
                key: const Key('main_default'),
                label: Text('Server default${snap.primaryDefault == null ? '' : ' (${snap.byId(snap.primaryDefault!)?.name ?? snap.primaryDefault})'}'),
                selected: _prefs.preferredProvider == null,
                onSelected: (_) => _save(_prefs.copyWith(clearPreferredProvider: true)),
              ),
              for (final ProviderInfo p in usable)
                ChoiceChip(
                  key: Key('main_${p.id}'),
                  label: Text(p.name),
                  selected: _prefs.preferredProvider == p.id && mainId == p.id,
                  onSelected: (_) => _save(_prefs.copyWith(preferredProvider: p.id)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fallbackCard(ThemeData theme, ProvidersSnapshot snap) {
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.4);
    final String mainId = _mainProviderId(snap);
    final List<ProviderInfo> candidates =
        snap.providers.where((ProviderInfo p) => p.configured && p.id != mainId).toList();
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            key: const Key('fallback_switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatic fallback'),
            subtitle: const Text(
              'Off by default. When on, if the main provider cannot answer, your message may be sent to the other providers you tick below.',
            ),
            value: _prefs.fallbackEnabled,
            onChanged: (bool on) => _save(_prefs.copyWith(fallbackEnabled: on)),
          ),
          if (!_prefs.fallbackEnabled)
            Text(
              'With fallback off, a failure shows an error and your message goes to no other company.',
              key: const Key('fallback_off_note'),
              style: small,
            ),
          if (_prefs.fallbackEnabled) ...<Widget>[
            const Divider(),
            const Text('Allowed fallback providers', style: TextStyle(fontWeight: FontWeight.w600)),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('No other provider is configured on your server.', style: small),
              ),
            for (final ProviderInfo p in candidates)
              Builder(
                builder: (BuildContext context) {
                  final bool blockedCost = !snap.allowPaidFallback && p.costPolicy != 'free_only';
                  final bool blocked = blockedCost || !p.fallbackEligible;
                  return CheckboxListTile(
                    key: Key('fallback_provider_${p.id}'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(p.name),
                    subtitle: Text(
                      !p.fallbackEligible
                          ? 'Excluded as a fallback by your server settings.'
                          : (blockedCost
                              ? 'Your server will not use it as a fallback because it is not declared free-only.'
                              : 'Your message may be sent here only if the main provider fails.'),
                    ),
                    value: _prefs.fallbackProviders.contains(p.id) && !blocked,
                    onChanged: blocked
                        ? null
                        : (bool? on) {
                            final Set<String> next = Set<String>.of(_prefs.fallbackProviders);
                            if (on == true) {
                              next.add(p.id);
                            } else {
                              next.remove(p.id);
                            }
                            unawaited(_save(_prefs.copyWith(fallbackProviders: next)));
                          },
                  );
                },
              ),
            const Divider(),
            SwitchListTile(
              key: const Key('share_memory_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Also share memory notes'),
              subtitle: const Text('Off: a fallback provider never sees your saved memories.'),
              value: _prefs.shareMemoryWithFallback,
              onChanged: (bool on) => _save(_prefs.copyWith(shareMemoryWithFallback: on)),
            ),
            SwitchListTile(
              key: const Key('share_files_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Also share attached file text'),
              subtitle: const Text(
                'Off: if you attached a file, no fallback is tried, because answering without the file would be wrong.',
              ),
              value: _prefs.shareFilesWithFallback,
              onChanged: (bool on) => _save(_prefs.copyWith(shareFilesWithFallback: on)),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI providers')),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[widget.status, widget.routing, widget.settings]),
        builder: (BuildContext context, Widget? _) {
          final ProvidersSnapshot? snap = widget.status.snapshot;
          final bool live = widget.settings.value.isConfigured;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: <Widget>[
              _whereProcessed(theme),
              if (live) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonal(
                        key: const Key('check_providers_button'),
                        onPressed: widget.status.isChecking ? null : widget.status.checkAll,
                        child: widget.status.isChecking
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Check connections'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Checking really contacts each provider through your backend. Until then, a provider is shown as "not checked yet", never as available.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (widget.status.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      widget.status.error!,
                      key: const Key('providers_error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (widget.status.isLoading && snap == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (snap != null) ...<Widget>[
                  const SizedBox(height: 12),
                  _mainProviderCard(theme, snap),
                  const SizedBox(height: 12),
                  for (final ProviderInfo p in snap.providers) _providerCard(theme, p, snap),
                  _fallbackCard(theme, snap),
                ],
              ],
              const SizedBox(height: 16),
              Text(
                'Free tiers, limits and model names change over time. ALMUS AI does not assume any provider stays free; '
                'model lists come from each provider live.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CapChip extends StatelessWidget {
  const _CapChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Chip(label: Text(text), visualDensity: VisualDensity.compact);
}

/// Bottom sheet listing the provider's live models.
class _ModelSheet extends StatelessWidget {
  const _ModelSheet({
    required this.provider,
    required this.status,
    required this.selected,
    required this.pending,
  });

  static const String useDefault = '__default__';

  final ProviderInfo provider;
  final ProviderStatusController status;
  final String? selected;
  final Future<List<ProviderModel>> pending;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<ProviderModel>>(
        future: pending,
        builder: (BuildContext context, AsyncSnapshot<List<ProviderModel>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
          }
          final List<ProviderModel> models = snap.data ?? const <ProviderModel>[];
          final String? err = status.modelError(provider.id);
          return ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(title: Text('Models from ${provider.name}', style: const TextStyle(fontWeight: FontWeight.w700))),
              ListTile(
                key: const Key('model_use_default'),
                leading: Icon(selected == null ? Icons.check_circle : Icons.circle_outlined),
                title: const Text('Use the server default'),
                onTap: () => Navigator.of(context).pop(useDefault),
              ),
              if (err != null) ListTile(title: Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              if (err == null && models.isEmpty)
                const ListTile(title: Text('The provider listed no models this server may use.')),
              for (final ProviderModel m in models)
                ListTile(
                  key: Key('model_${m.id}'),
                  leading: Icon(selected == m.id ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(m.id),
                  subtitle: Text(<String>[
                    if (m.contextTokens != null) '${m.contextTokens} token context',
                    if (m.free == true) 'free',
                  ].join(' · ')),
                  onTap: () => Navigator.of(context).pop(m.id),
                ),
            ],
          );
        },
      ),
    );
  }
}
