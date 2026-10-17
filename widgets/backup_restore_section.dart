import 'dart:async';

import 'package:flutter/material.dart';

import '../backup/backup_controller.dart';
import '../backup/backup_crypto.dart';
import '../backup/backup_files.dart';
import '../backup/backup_models.dart';
import '../backup/backup_store.dart';
import '../backup/import_adapters.dart';
import '../backup/transcript_formats.dart';
import '../models/conversation.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import 'glow_card.dart';

/// Settings card: export, complete backup, import and restore.
class BackupRestoreCard extends StatefulWidget {
  const BackupRestoreCard({super.key, required this.controller});

  final BackupController controller;

  @override
  State<BackupRestoreCard> createState() => _BackupRestoreCardState();
}

class _BackupRestoreCardState extends State<BackupRestoreCard> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.loadInfo());
  }

  BackupController get _c => widget.controller;

  Future<void> _exportAll() async {
    final TranscriptFormat? format = await _chooseTranscriptFormat(context);
    if (format == null || !mounted) return;
    await _c.exportConversations(format: format);
  }

  Future<void> _exportSelected() async {
    final Set<String>? ids = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute<Set<String>>(
        builder: (_) => ConversationPickerScreen(controller: _c),
      ),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    final TranscriptFormat? format = await _chooseTranscriptFormat(context);
    if (format == null || !mounted) return;
    await _c.exportConversations(ids: ids, format: format);
  }

  Future<void> _exportMemory() async {
    final MemoryExportFormat? format = await showModalBottomSheet<MemoryExportFormat>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Export personal memory as',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final MemoryExportFormat f in MemoryExportFormat.values)
              ListTile(
                key: Key('memory_format_${f.name}'),
                title: Text(f.label),
                onTap: () => Navigator.of(ctx).pop(f),
              ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    await _c.exportMemories(format);
  }

  Future<void> _createBackup() async {
    final _BackupChoice? choice = await showDialog<_BackupChoice>(
      context: context,
      builder: (_) => const _CreateBackupDialog(),
    );
    if (choice == null || !mounted) return;
    await _c.createCompleteBackup(password: choice.password);
  }

  Future<void> _import() async {
    final PickResult result = await _c.pickBackupFile();
    if (!mounted) return;
    if (result == PickResult.needsPassword) {
      final bool unlocked = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _UnlockDialog(controller: _c),
          ) ??
          false;
      if (!unlocked || !mounted) {
        _c.discardPending();
        return;
      }
    } else if (result != PickResult.ready) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ImportPreviewScreen(controller: _c),
      ),
    );
    // Leaving the preview without importing discards the parsed file.
    if (_c.pending != null && !_c.isBusy) _c.discardPending();
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
      listenable: _c,
      builder: (BuildContext context, Widget? _) {
        final bool busy = _c.isBusy;
        final BackupInfo info = _c.info;
        return GlowCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Save your chats and memories to a file that YOU choose, so you can restore them later, even after reinstalling the app. Nothing is uploaded: you pick the location (Downloads, a memory card, or a cloud app you use yourself).',
                style: small,
              ),
              const SizedBox(height: 12),
              _InfoLine(
                icon: Icons.history_toggle_off,
                title: 'Last complete backup',
                value: info.lastBackupAt == null
                    ? 'None yet'
                    : '${formatRelativeDate(info.lastBackupAt!)}'
                        '${info.lastBackupLabel == null ? '' : '\n${info.lastBackupLabel}'}',
              ),
              if (info.lastRestoreAt != null) ...<Widget>[
                const SizedBox(height: 8),
                _InfoLine(
                  icon: Icons.settings_backup_restore,
                  title: 'Last restore',
                  value: formatRelativeDate(info.lastRestoreAt!),
                ),
              ],
              Divider(height: 24, color: cs.outlineVariant),
              _ActionTile(
                tileKey: const Key('backup_export_all'),
                icon: Icons.download_outlined,
                title: 'Export all conversations',
                subtitle: 'JSON, Markdown or plain text',
                onTap: busy ? null : _exportAll,
              ),
              _ActionTile(
                tileKey: const Key('backup_export_selected'),
                icon: Icons.checklist_rtl,
                title: 'Export selected conversations',
                subtitle: 'Choose which chats to include',
                onTap: busy ? null : _exportSelected,
              ),
              _ActionTile(
                tileKey: const Key('backup_export_memory'),
                icon: Icons.psychology_outlined,
                title: 'Export personal memory',
                subtitle: 'JSON or Markdown',
                onTap: busy ? null : _exportMemory,
              ),
              _ActionTile(
                tileKey: const Key('backup_create'),
                icon: Icons.archive_outlined,
                title: 'Create complete backup',
                subtitle: 'ZIP with chats, memory and settings; optional password',
                onTap: busy ? null : _createBackup,
              ),
              _ActionTile(
                tileKey: const Key('backup_import'),
                icon: Icons.upload_file_outlined,
                title: 'Import backup',
                subtitle: 'Restore or merge from a file, with a preview first',
                onTap: busy ? null : _import,
              ),
              _StatusPanel(controller: _c),
              const SizedBox(height: 10),
              Text(
                'Exports and ordinary backups are NOT encrypted: anyone who gets the file can read it. Choose a password when creating a complete backup to encrypt it. If you forget that password the backup cannot be opened by anyone, including us. Provider keys, access tokens and app-lock data are never included.',
                style: small,
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<TranscriptFormat?> _chooseTranscriptFormat(BuildContext context) {
  return showModalBottomSheet<TranscriptFormat>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Export as',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          for (final TranscriptFormat f in TranscriptFormat.values)
            ListTile(
              key: Key('transcript_format_${f.name}'),
              title: Text(f.label),
              onTap: () => Navigator.of(ctx).pop(f),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'JSON keeps everything and can be imported again exactly. Markdown and text are for reading (line endings are normalised when imported back).',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.title, required this.value});

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(value, style: TextStyle(color: cs.onSurfaceVariant, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: tileKey,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: onTap == null ? null : Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      enabled: onTap != null,
      onTap: onTap,
    );
  }
}

/// Progress while a task runs, and the success / failure message afterwards.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});

  final BackupController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    if (controller.isBusy) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          key: const Key('backup_progress'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(value: controller.fraction),
            const SizedBox(height: 8),
            Text(controller.stage, style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    final String? message = controller.message;
    if (message == null) return const SizedBox.shrink();
    final bool error = controller.messageIsError;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        key: Key(error ? 'backup_failure' : 'backup_success'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            error ? Icons.error_outline : Icons.check_circle_outline,
            size: 20,
            color: error ? cs.error : AlmusColors.mint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: error ? cs.error : cs.onSurface, height: 1.4),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: controller.dismissMessage,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ dialogs

class _BackupChoice {
  const _BackupChoice(this.password);

  /// null = not encrypted.
  final String? password;
}

class _CreateBackupDialog extends StatefulWidget {
  const _CreateBackupDialog();

  @override
  State<_CreateBackupDialog> createState() => _CreateBackupDialogState();
}

class _CreateBackupDialogState extends State<_CreateBackupDialog> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _encrypt = true;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_encrypt) {
      Navigator.of(context).pop(const _BackupChoice(null));
      return;
    }
    final String? problem = BackupCrypto.passwordProblem(_password.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'The two passwords are not the same.');
      return;
    }
    Navigator.of(context).pop(_BackupChoice(_password.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create complete backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SwitchListTile(
              key: const Key('backup_encrypt_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Protect with a password'),
              subtitle: Text(
                _encrypt
                    ? 'Encrypted backup (.almusenc)'
                    : 'NOT encrypted: anyone with the file can read your chats (.zip)',
              ),
              value: _encrypt,
              onChanged: (bool v) => setState(() {
                _encrypt = v;
                _error = null;
              }),
            ),
            if (_encrypt) ...<Widget>[
              TextField(
                key: const Key('backup_password_field'),
                controller: _password,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Password (at least $kMinPasswordLength characters)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Hide' : 'Show',
                    onPressed: () => setState(() => _show = !_show),
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('backup_password_confirm_field'),
                controller: _confirm,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Repeat password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'There is no password recovery. Store the password somewhere safe. Typing the same characters (and the same keyboard) is required to open the backup.',
                style: TextStyle(fontSize: 12),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('backup_dialog_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('backup_dialog_create'),
          onPressed: _submit,
          child: const Text('Choose where to save'),
        ),
      ],
    );
  }
}

class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog({required this.controller});

  final BackupController controller;

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final TextEditingController _password = TextEditingController();
  bool _working = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the password.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final String? error = await widget.controller.unlockPending(_password.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _working = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Encrypted backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Enter the password you chose when this backup was created.'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('unlock_password_field'),
            controller: _password,
            enabled: !_working,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _show ? 'Hide' : 'Show',
                onPressed: () => setState(() => _show = !_show),
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              ),
            ),
            onSubmitted: (_) => _unlock(),
          ),
          if (_working) ...<Widget>[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            const Text('Decrypting…', style: TextStyle(fontSize: 12)),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _error!,
              key: const Key('unlock_error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('unlock_submit'),
          onPressed: _working ? null : _unlock,
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

// -------------------------------------------------- conversation selection

/// Lets the user tick the conversations to export. Returns their ids.
class ConversationPickerScreen extends StatefulWidget {
  const ConversationPickerScreen({super.key, required this.controller});

  final BackupController controller;

  @override
  State<ConversationPickerScreen> createState() => _ConversationPickerScreenState();
}

class _ConversationPickerScreenState extends State<ConversationPickerScreen> {
  List<Conversation>? _items;
  String? _error;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<Conversation> items = await widget.controller.listConversations();
      if (!mounted) return;
      setState(() => _items = items);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Your conversations could not be loaded.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Conversation>? items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select conversations'),
        actions: <Widget>[
          if (items != null && items.isNotEmpty)
            TextButton(
              key: const Key('picker_select_all'),
              onPressed: () => setState(() {
                if (_selected.length == items.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(items.map((Conversation c) => c.id));
                }
              }),
              child: Text(_selected.length == items.length ? 'Clear' : 'Select all'),
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? const Center(child: Text('There are no conversations yet.'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Conversation c = items[index];
                        return CheckboxListTile(
                          key: Key('picker_${c.id}'),
                          value: _selected.contains(c.id),
                          onChanged: (bool? on) => setState(() {
                            if (on ?? false) {
                              _selected.add(c.id);
                            } else {
                              _selected.remove(c.id);
                            }
                          }),
                          title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${c.messageCount} message${c.messageCount == 1 ? '' : 's'} · ${formatRelativeDate(c.updatedAt)}',
                          ),
                        );
                      },
                    ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            key: const Key('picker_continue'),
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(Set<String>.of(_selected)),
            child: Text('Continue with ${_selected.length} selected'),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- import preview

/// Shows what a backup contains and what an import would change. Nothing is
/// stored until the user presses the import button (and, for replace, confirms).
class ImportPreviewScreen extends StatefulWidget {
  const ImportPreviewScreen({super.key, required this.controller});

  final BackupController controller;

  @override
  State<ImportPreviewScreen> createState() => _ImportPreviewScreenState();
}

class _ImportPreviewScreenState extends State<ImportPreviewScreen> {
  late ImportOptions _options;
  ImportSummary? _summary;
  StoreCounts _current = const StoreCounts();
  String? _planError;
  int _token = 0;

  BackupController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    final BackupBundle b = _c.pending!.bundle;
    _options = ImportOptions(
      conversations: b.conversations.isNotEmpty,
      memories: b.memories.isNotEmpty,
      settings: b.settings != null,
    );
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final int token = ++_token;
    try {
      final ImportSummary summary = await _c.previewFor(_options);
      final StoreCounts current = await _c.currentCounts();
      if (!mounted || token != _token) return;
      setState(() {
        _summary = summary;
        _current = current;
        _planError = null;
      });
    } on BackupException catch (e) {
      if (!mounted || token != _token) return;
      setState(() => _planError = e.message);
    } on Object {
      if (!mounted || token != _token) return;
      setState(() => _planError = 'The preview could not be calculated.');
    }
  }

  void _change(ImportOptions options) {
    setState(() {
      _options = options;
      _summary = null;
    });
    unawaited(_refresh());
  }

  bool get _anySelected => _options.conversations || _options.memories || _options.settings;

  Future<void> _start() async {
    bool safety = false;
    if (_options.mode == ImportMode.replace) {
      final bool? choice = await showDialog<bool>(
        context: context,
        builder: (_) => _ReplaceConfirmDialog(
          removed: _summary?.removed ?? const StoreCounts(),
          options: _options,
          incoming: _c.pending!.bundle,
        ),
      );
      if (choice == null || !mounted) return;
      safety = choice;
    }
    await _c.runImport(_options, safetyBackup: safety);
    if (!mounted) return;
    if (_c.pending == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (BuildContext context, Widget? _) {
        final PendingImport? pending = _c.pending;
        final bool busy = _c.isBusy;
        return PopScope(
          canPop: !busy,
          child: Scaffold(
            appBar: AppBar(title: const Text('Restore preview')),
            body: pending == null
                ? const Center(child: Text('Nothing to import.'))
                : _body(context, pending, busy),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, PendingImport pending, bool busy) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final BackupBundle b = pending.bundle;
    final ParsedImport parsed = pending.parsed;
    final ImportSummary? s = _summary;
    final bool replace = _options.mode == ImportMode.replace;
    final TextStyle? small = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      height: 1.4,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(pending.fileName, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(parsed.source.label),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Icon(
                    parsed.encrypted ? Icons.lock_outline : Icons.lock_open_outlined,
                    size: 18,
                    color: parsed.encrypted ? AlmusColors.mint : AlmusColors.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      parsed.encrypted
                          ? 'Encrypted backup (AES-256-GCM); the password was correct.'
                          : 'Not encrypted: anyone with this file can read it.',
                      style: small,
                    ),
                  ),
                ],
              ),
              if (b.appVersion.isNotEmpty || b.exportedAt != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Created${b.appVersion.isEmpty ? '' : ' by ALMUS AI ${b.appVersion}'}'
                  '${b.exportedAt == null ? '' : ' · ${formatRelativeDate(b.exportedAt!.toLocal())}'}'
                  ' · format version ${b.schemaVersion}',
                  style: small,
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
              const Text('Choose what to import', style: TextStyle(fontWeight: FontWeight.w700)),
              CheckboxListTile(
                key: const Key('import_conversations'),
                contentPadding: EdgeInsets.zero,
                value: _options.conversations,
                onChanged: busy || b.conversations.isEmpty
                    ? null
                    : (bool? v) => _change(_options.copyWith(conversations: v ?? false)),
                title: Text(
                  'Conversations (${b.conversations.length}) · ${b.messageCount} messages',
                ),
              ),
              CheckboxListTile(
                key: const Key('import_memories'),
                contentPadding: EdgeInsets.zero,
                value: _options.memories,
                onChanged: busy || b.memories.isEmpty
                    ? null
                    : (bool? v) => _change(_options.copyWith(memories: v ?? false)),
                title: Text('Personal memories (${b.memories.length})'),
              ),
              if (b.settings != null)
                CheckboxListTile(
                  key: const Key('import_settings'),
                  contentPadding: EdgeInsets.zero,
                  value: _options.settings,
                  onChanged: busy
                      ? null
                      : (bool? v) => _change(_options.copyWith(settings: v ?? false)),
                  title: const Text('Memory settings'),
                  subtitle: const Text('Memory on/off and per-chat memory switches'),
                ),
              if (b.isEmpty)
                Text('This backup is empty: it contains no conversations or memories.', style: small),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('How should it be restored?', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ImportMode>(
                  key: const Key('import_mode'),
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<ImportMode>>[
                    ButtonSegment<ImportMode>(value: ImportMode.merge, label: Text('Merge')),
                    ButtonSegment<ImportMode>(value: ImportMode.replace, label: Text('Replace')),
                  ],
                  selected: <ImportMode>{_options.mode},
                  onSelectionChanged: busy
                      ? null
                      : (Set<ImportMode> v) => _change(_options.copyWith(mode: v.first)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                replace
                    ? 'Replace deletes the selected data that is on this phone now and puts the backup in its place. It needs your confirmation. Other app data (app lock, voice and connection settings) is not touched.'
                    : 'Merge keeps everything on this phone and adds only what is missing. Records that already exist (same id) are never overwritten.',
                style: small,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlowCard(
          child: _planBody(s, replace, small),
        ),
        if (b.warnings.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          GlowCard(
            glowColor: AlmusColors.amber,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Notes about this file', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final String w in b.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $w', style: small),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (busy) ...<Widget>[
          Column(
            key: const Key('import_progress'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LinearProgressIndicator(value: _c.fraction),
              const SizedBox(height: 8),
              Text(_c.stage),
            ],
          ),
        ] else ...<Widget>[
          if (_c.message != null && _c.messageIsError)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _c.message!,
                key: const Key('import_error'),
                style: TextStyle(color: cs.error, height: 1.4),
              ),
            ),
          FilledButton.icon(
            key: const Key('import_start'),
            onPressed: (_anySelected && s != null) ? _start : null,
            icon: Icon(replace ? Icons.restore : Icons.merge_type),
            label: Text(replace ? 'Replace with this backup…' : 'Merge into this phone'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('import_cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel (nothing is changed)'),
          ),
        ],
      ],
    );
  }

  Widget _planBody(ImportSummary? s, bool replace, TextStyle? small) {
    if (_planError != null) {
      return Text(_planError!, key: const Key('import_plan_error'));
    }
    if (s == null) {
      return const Row(
        children: <Widget>[
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Comparing with your data…'),
        ],
      );
    }
    final List<String> lines = <String>[
      if (replace)
        'Will be removed from this phone: ${s.removed.conversations} conversations, ${s.removed.messages} messages, ${s.removed.memories} memories.',
      'New: ${s.newConversations} conversations, ${s.newMessages} messages, ${s.newMemories} memories.',
      if (s.mergedConversations > 0)
        '${s.mergedConversations} existing conversations will receive messages they are missing.',
      if (s.duplicateConversations + s.duplicateMessages + s.duplicateMemories > 0)
        'Already on this phone (skipped): ${s.duplicateConversations} conversations, ${s.duplicateMessages} messages, ${s.duplicateMemories} memories.',
      if (s.conflictingMessages > 0)
        '${s.conflictingMessages} messages have ids that belong to other chats here and will be skipped.',
      if (s.settingsApplied) 'Memory settings will be applied.',
      if (!replace) 'This phone now has: ${_current.conversations} conversations, ${_current.memories} memories.',
    ];
    return Column(
      key: const Key('import_plan'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('What will happen', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: small),
          ),
      ],
    );
  }
}

class _ReplaceConfirmDialog extends StatefulWidget {
  const _ReplaceConfirmDialog({
    required this.removed,
    required this.options,
    required this.incoming,
  });

  final StoreCounts removed;
  final ImportOptions options;
  final BackupBundle incoming;

  @override
  State<_ReplaceConfirmDialog> createState() => _ReplaceConfirmDialogState();
}

class _ReplaceConfirmDialogState extends State<_ReplaceConfirmDialog> {
  bool _safety = true;

  @override
  Widget build(BuildContext context) {
    final StoreCounts r = widget.removed;
    final BackupBundle b = widget.incoming;
    return AlertDialog(
      title: const Text('Replace your data?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This will delete ${r.conversations} conversations, ${r.messages} messages and ${r.memories} memories that are on this phone now.',
              key: const Key('replace_removed'),
            ),
            const SizedBox(height: 8),
            Text(
              'They will be replaced by ${widget.options.conversations ? b.conversations.length : 0} conversations, '
              '${widget.options.conversations ? b.messageCount : 0} messages and '
              '${widget.options.memories ? b.memories.length : 0} memories from the backup.',
            ),
            const SizedBox(height: 8),
            const Text(
              'If the import fails, nothing is deleted. After it succeeds, deleted data cannot be undone unless you have a backup.',
            ),
            CheckboxListTile(
              key: const Key('replace_safety_backup'),
              contentPadding: EdgeInsets.zero,
              value: _safety,
              onChanged: (bool? v) => setState(() => _safety = v ?? false),
              title: const Text('Save a safety backup of my current data first (recommended)'),
              subtitle: const Text('Not encrypted. You choose where it is saved.'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('replace_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('replace_confirm'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.of(context).pop(_safety),
          child: const Text('Replace'),
        ),
      ],
    );
  }
}
