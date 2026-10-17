import 'package:flutter/material.dart';

import '../controllers/memory_controller.dart';
import '../models/memory_item.dart';

/// What the user typed in the memory editor.
class MemoryDraft {
  const MemoryDraft(this.category, this.text);

  final MemoryCategory category;
  final String text;
}

IconData memoryCategoryIcon(MemoryCategory category) {
  return switch (category) {
    MemoryCategory.profile => Icons.person_outline,
    MemoryCategory.preference => Icons.tune,
    MemoryCategory.learning => Icons.school_outlined,
    MemoryCategory.project => Icons.work_outline,
    MemoryCategory.goal => Icons.flag_outlined,
    MemoryCategory.fact => Icons.verified_outlined,
    MemoryCategory.summary => Icons.summarize_outlined,
  };
}

void showMemoryToast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Dialog to write or edit one memory (text plus category).
Future<MemoryDraft?> showMemoryEditor(
  BuildContext context, {
  required String title,
  required MemoryCategory category,
  String text = '',
  String? helper,
}) {
  return showDialog<MemoryDraft>(
    context: context,
    builder: (BuildContext ctx) => _MemoryEditorDialog(
      title: title,
      category: category,
      text: text,
      helper: helper,
    ),
  );
}

class _MemoryEditorDialog extends StatefulWidget {
  const _MemoryEditorDialog({
    required this.title,
    required this.category,
    required this.text,
    this.helper,
  });

  final String title;
  final MemoryCategory category;
  final String text;
  final String? helper;

  @override
  State<_MemoryEditorDialog> createState() => _MemoryEditorDialogState();
}

class _MemoryEditorDialogState extends State<_MemoryEditorDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);
  late MemoryCategory _category = widget.category;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.helper != null) ...<Widget>[
              Text(
                widget.helper!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('memory_text_field'),
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              maxLength: kMaxMemoryChars,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'For example: I prefer short answers',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final MemoryCategory c in MemoryCategory.values)
                  ChoiceChip(
                    key: Key('category_${c.key}'),
                    label: Text(c.label),
                    selected: _category == c,
                    onSelected: (bool _) => setState(() => _category = c),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('memory_save_button'),
          onPressed: () =>
              Navigator.of(context).pop(MemoryDraft(_category, _controller.text)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Future<bool> _confirmSensitive(BuildContext context, String message) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('Sensitive information'),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Do not save'),
        ),
        FilledButton(
          key: const Key('confirm_sensitive'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Opens the editor and saves a new memory. Sensitive text needs a second,
/// explicit confirmation; secrets are refused. Returns true when saved.
Future<bool> addMemoryFlow(
  BuildContext context,
  MemoryController memory, {
  String title = 'Add a memory',
  MemoryCategory category = MemoryCategory.fact,
  String text = '',
  String? sourceConversationId,
  String? helper,
}) async {
  final MemoryDraft? draft = await showMemoryEditor(
    context,
    title: title,
    category: category,
    text: text,
    helper: helper,
  );
  if (draft == null || !context.mounted) return false;
  MemorySaveResult result = await memory.add(
    category: draft.category,
    text: draft.text,
    sourceConversationId: sourceConversationId,
  );
  if (result.status == MemorySaveStatus.needsConfirmation) {
    if (!context.mounted) return false;
    if (!await _confirmSensitive(context, result.message)) return false;
    result = await memory.add(
      category: draft.category,
      text: draft.text,
      sourceConversationId: sourceConversationId,
      allowSensitive: true,
    );
  }
  if (context.mounted) {
    showMemoryToast(context, result.isSaved ? 'Memory saved.' : result.message);
  }
  return result.isSaved;
}

/// Opens the editor for an existing memory and saves the change.
Future<bool> editMemoryFlow(
  BuildContext context,
  MemoryController memory,
  MemoryItem item,
) async {
  final MemoryDraft? draft = await showMemoryEditor(
    context,
    title: 'Edit memory',
    category: item.category,
    text: item.text,
  );
  if (draft == null || !context.mounted) return false;
  MemorySaveResult result = await memory.edit(
    item.id,
    category: draft.category,
    text: draft.text,
  );
  if (result.status == MemorySaveStatus.needsConfirmation) {
    if (!context.mounted) return false;
    if (!await _confirmSensitive(context, result.message)) return false;
    result = await memory.edit(
      item.id,
      category: draft.category,
      text: draft.text,
      allowSensitive: true,
    );
  }
  if (context.mounted) {
    showMemoryToast(context, result.isSaved ? 'Memory updated.' : result.message);
  }
  return result.isSaved;
}

/// Approves a suggested memory (asks again first if it looks sensitive).
Future<bool> confirmSuggestionFlow(
  BuildContext context,
  MemoryController memory,
  MemoryItem item,
) async {
  MemorySaveResult result = await memory.confirm(item.id);
  if (result.status == MemorySaveStatus.needsConfirmation) {
    if (!context.mounted) return false;
    if (!await _confirmSensitive(context, result.message)) return false;
    result = await memory.confirm(item.id, allowSensitive: true);
  }
  if (context.mounted) {
    showMemoryToast(context, result.isSaved ? 'Memory saved.' : result.message);
  }
  return result.isSaved;
}

/// Lists the memories that were sent with the latest AI request.
Future<void> showUsedMemoriesSheet(
  BuildContext context,
  List<MemoryItem> items,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext ctx) {
      final ThemeData theme = Theme.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: <Widget>[
              Text(
                'Memories sent with your last message',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'These were included in the request to your backend and Gemini because they matched your message. Nothing else from your memory was sent.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              for (final MemoryItem item in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(memoryCategoryIcon(item.category)),
                  title: Text(item.text),
                  subtitle: Text(item.category.label),
                ),
            ],
          ),
        ),
      );
    },
  );
}
