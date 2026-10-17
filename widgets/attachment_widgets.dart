import 'package:flutter/material.dart';

import '../attachments/attachment_controller.dart';
import '../attachments/attachment_models.dart';
import '../attachments/attachment_picker.dart';
import '../attachments/attachment_plan.dart';
import '../theme/app_theme.dart';

/// Bottom sheet listing what can be attached. Returns the chosen source.
Future<AttachmentSource?> showAttachmentSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentSource>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Attach a file', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Files stay on your phone until you send the message. Only the text found in documents is sent to the AI.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            _option(ctx, AttachmentSource.image, Icons.image_outlined, 'attach_image',
                'Shown in the chat. The AI cannot analyze images yet.'),
            _option(ctx, AttachmentSource.camera, Icons.photo_camera_outlined, 'attach_camera',
                'Uses your camera app'),
            _option(ctx, AttachmentSource.document, Icons.description_outlined, 'attach_document',
                'Word, PDF, text, CSV and Excel files'),
            _option(ctx, AttachmentSource.pdf, Icons.picture_as_pdf_outlined, 'attach_pdf',
                'Text PDFs only (scans are not read)'),
            _option(ctx, AttachmentSource.text, Icons.article_outlined, 'attach_text',
                'TXT, Markdown, LOG, JSON'),
            _option(ctx, AttachmentSource.spreadsheet, Icons.table_chart_outlined, 'attach_spreadsheet',
                'CSV, TSV or XLSX'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

Widget _option(BuildContext ctx, AttachmentSource s, IconData icon, String key, String subtitle) {
  return ListTile(
    key: Key(key),
    leading: Icon(icon),
    title: Text(s.label),
    subtitle: Text(subtitle),
    onTap: () => Navigator.of(ctx).pop(s),
  );
}

IconData _iconFor(AttachmentKind? kind) {
  switch (kind) {
    case AttachmentKind.image:
      return Icons.image_outlined;
    case AttachmentKind.pdf:
      return Icons.picture_as_pdf_outlined;
    case AttachmentKind.docx:
      return Icons.description_outlined;
    case AttachmentKind.xlsx:
    case AttachmentKind.csv:
      return Icons.table_chart_outlined;
    case AttachmentKind.text:
    case AttachmentKind.markdown:
      return Icons.article_outlined;
    case null:
      return Icons.insert_drive_file_outlined;
  }
}

/// The files waiting to be sent, with thumbnails, size, status and a remove
/// button. Also shows validation problems.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({super.key, required this.controller, required this.support});

  final AttachmentController controller;
  final AttachmentSupport support;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<ChatAttachment> items = controller.items;
    final List<String> problems = controller.problems;
    if (items.isEmpty && problems.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (problems.isNotEmpty)
          Container(
            key: const Key('attachment_problems'),
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.error.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: cs.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final String p in problems)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(p, style: const TextStyle(fontSize: 12.5, height: 1.3)),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('attachment_problems_dismiss'),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.dismissProblems,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        if (items.isNotEmpty)
          SizedBox(
            key: const Key('attachment_strip'),
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              itemCount: items.length,
              separatorBuilder: (BuildContext _, int __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) => _AttachmentChip(
                attachment: items[i],
                support: support,
                onRemove: () => controller.remove(items[i].id),
              ),
            ),
          ),
      ],
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.support,
    required this.onRemove,
  });

  final ChatAttachment attachment;
  final AttachmentSupport support;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ChatAttachment a = attachment;
    String status;
    Color statusColor = cs.onSurfaceVariant;
    if (!a.isReady) {
      status = 'Reading…';
    } else if (a.isImage) {
      status = 'Not analyzed by the AI';
      statusColor = AlmusColors.amber;
    } else if (!support.extractedText) {
      status = 'Not read by ${support.providerName}';
      statusColor = AlmusColors.amber;
    } else {
      status = a.truncated ? 'Text ready (shortened)' : 'Text ready';
      statusColor = AlmusColors.mint;
    }
    return Container(
      key: Key('attachment_${a.id}'),
      width: 218,
      padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: a.thumbnail != null
                  ? Image.memory(
                      a.thumbnail!,
                      key: Key('thumb_${a.id}'),
                      fit: BoxFit.cover,
                      cacheWidth: 96,
                      gaplessPlayback: true,
                      errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                          const Icon(Icons.broken_image_outlined),
                    )
                  : Icon(_iconFor(a.kind), size: 28, color: cs.primary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text(
                  '${a.kind?.label ?? 'File'} · ${formatFileSize(a.sizeBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
                Row(
                  children: <Widget>[
                    if (!a.isReady)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6)),
                      ),
                    Expanded(
                      child: Text(
                        status,
                        key: Key('status_${a.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: statusColor),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('remove_${a.id}'),
            tooltip: 'Remove attachment',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Files shown under a sent message (name, size and whether the AI read it).
class MessageAttachmentList extends StatelessWidget {
  const MessageAttachmentList({super.key, required this.items, required this.onUserBubble});

  final List<AttachmentInfo> items;
  final bool onUserBubble;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final Color text = onUserBubble ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final AttachmentInfo a in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (a.thumbnail != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        a.thumbnail!,
                        width: 40,
                        height: 40,
                        cacheWidth: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                            Icon(Icons.broken_image_outlined, size: 20, color: text),
                      ),
                    )
                  else
                    Icon(Icons.attach_file, size: 18, color: text),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${a.name} · ${formatFileSize(a.sizeBytes)}${a.analyzed ? '' : ' · not analyzed'}',
                      key: Key('sent_attachment_${a.name}'),
                      style: TextStyle(fontSize: 12, color: text.withValues(alpha: 0.9)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
