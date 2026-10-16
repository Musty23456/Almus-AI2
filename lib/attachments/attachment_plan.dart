import '../models/chat_message.dart';
import '../services/chat_service.dart';
import 'attachment_models.dart';

/// What an AI connection can actually read. Choosing a file and analysing it
/// are separate: a file may be attachable but not analysable.
class AttachmentSupport {
  const AttachmentSupport({
    this.extractedText = false,
    this.images = false,
    this.providerName = 'this assistant',
  });

  /// Can receive text the app extracted from documents.
  final bool extractedText;

  /// Can receive image pixels (no connection does yet).
  final bool images;
  final String providerName;

  static const AttachmentSupport none = AttachmentSupport(providerName: 'DEMO MODE');
}

/// A chat engine that can receive extracted file text. Engines that do not
/// implement this get no file content at all.
abstract class AttachmentCapableChatService implements ChatService {
  AttachmentSupport get attachmentSupport;

  /// Like [reply], plus [attachments] (text extracted on the phone).
  Future<String> replyWithAttachments(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
    required List<ChatAttachment> attachments,
  });
}

class SkippedAttachment {
  const SkippedAttachment(this.attachment, this.reason);

  final ChatAttachment attachment;
  final String reason;
}

/// Which attached files the AI will really receive, and which it will not.
class AttachmentPlan {
  const AttachmentPlan({required this.analyzable, required this.skipped});

  final List<ChatAttachment> analyzable;
  final List<SkippedAttachment> skipped;

  bool get isEmpty => analyzable.isEmpty && skipped.isEmpty;
}

AttachmentPlan planAttachments(
  List<ChatAttachment> items,
  AttachmentSupport support,
) {
  final List<ChatAttachment> ok = <ChatAttachment>[];
  final List<SkippedAttachment> skipped = <SkippedAttachment>[];
  for (final ChatAttachment a in items) {
    if (a.isImage) {
      skipped.add(
        SkippedAttachment(
          a,
          'images cannot be analyzed by ${support.providerName} (it only receives text)',
        ),
      );
    } else if (!support.extractedText) {
      skipped.add(
        SkippedAttachment(a, '${support.providerName} does not read attached files'),
      );
    } else if (!a.hasText) {
      skipped.add(SkippedAttachment(a, 'no text could be read from it'));
    } else {
      ok.add(a);
    }
  }
  return AttachmentPlan(analyzable: ok, skipped: skipped);
}

/// Lines appended to the stored user message so the history always says
/// what was attached and whether it was really read.
String attachmentFooter(AttachmentPlan plan) {
  if (plan.isEmpty) return '';
  final StringBuffer b = StringBuffer();
  for (final ChatAttachment a in plan.analyzable) {
    b.write('\n📎 ${a.name} · ${formatFileSize(a.sizeBytes)} · text sent to the AI');
    if (a.truncated) b.write(' (shortened)');
  }
  for (final SkippedAttachment s in plan.skipped) {
    b.write('\n📎 ${s.attachment.name} · ${formatFileSize(s.attachment.sizeBytes)} · NOT analyzed');
  }
  return b.toString();
}

/// Per-message metadata for the chat bubble.
List<AttachmentInfo> attachmentInfos(AttachmentPlan plan) {
  return <AttachmentInfo>[
    for (final ChatAttachment a in plan.analyzable)
      AttachmentInfo(
        name: a.name,
        kindLabel: a.kind?.label ?? 'File',
        sizeBytes: a.sizeBytes,
        analyzed: true,
        note: a.truncated ? 'Text was shortened' : null,
      ),
    for (final SkippedAttachment s in plan.skipped)
      AttachmentInfo(
        name: s.attachment.name,
        kindLabel: s.attachment.kind?.label ?? 'File',
        sizeBytes: s.attachment.sizeBytes,
        analyzed: false,
        note: 'Not analyzed: ${s.reason}',
        thumbnail: s.attachment.thumbnail,
      ),
  ];
}
