import 'dart:typed_data';

/// Largest file the app will read (bytes), for documents and for images.
const int kMaxDocumentBytes = 10 * 1024 * 1024;
const int kMaxImageBytes = 10 * 1024 * 1024;

/// How many files can wait in the message box at once.
const int kMaxAttachments = 5;

/// Text limits. They match the backend (MAX_ATTACHMENT_CHARS / _TOTAL_CHARS).
const int kMaxExtractedChars = 30000;
const int kMaxTotalExtractedChars = 60000;

/// What a file really is (decided from its content, never from its name).
enum AttachmentKind {
  image('Image', null),
  pdf('PDF', 'pdf'),
  docx('Word document', 'docx'),
  xlsx('Excel spreadsheet', 'xlsx'),
  text('Text file', 'text'),
  markdown('Markdown file', 'markdown'),
  csv('CSV table', 'csv');

  const AttachmentKind(this.label, this.apiKind);

  final String label;

  /// Kind name the backend accepts; null when the backend cannot read it.
  final String? apiKind;

  bool get isImage => this == AttachmentKind.image;
}

enum AttachmentStatus { reading, ready }

/// A problem with one file. [message] is safe to show (it never contains
/// file content).
class AttachmentException implements Exception {
  const AttachmentException(this.message);

  final String message;

  @override
  String toString() => 'AttachmentException: $message';
}

/// A file waiting in the message box.
class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.name,
    required this.sizeBytes,
    this.kind,
    this.status = AttachmentStatus.reading,
    this.extractedText,
    this.truncated = false,
    this.thumbnail,
  });

  final String id;
  final String name;
  final int sizeBytes;

  /// Known once the file has been checked.
  final AttachmentKind? kind;
  final AttachmentStatus status;

  /// Text read on the phone (null for images).
  final String? extractedText;

  /// True when the text was shortened to fit the limits.
  final bool truncated;

  /// Image bytes for the preview (images only).
  final Uint8List? thumbnail;

  bool get isReady => status == AttachmentStatus.ready;
  bool get isImage => kind == AttachmentKind.image;
  bool get hasText => (extractedText ?? '').isNotEmpty;

  ChatAttachment copyWith({
    AttachmentKind? kind,
    AttachmentStatus? status,
    String? extractedText,
    bool? truncated,
    Uint8List? thumbnail,
  }) {
    return ChatAttachment(
      id: id,
      name: name,
      sizeBytes: sizeBytes,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      extractedText: extractedText ?? this.extractedText,
      truncated: truncated ?? this.truncated,
      thumbnail: thumbnail ?? this.thumbnail,
    );
  }
}

/// What a sent message remembers about a file (shown on the chat bubble).
/// File content itself is not kept.
class AttachmentInfo {
  const AttachmentInfo({
    required this.name,
    required this.kindLabel,
    required this.sizeBytes,
    required this.analyzed,
    this.note,
    this.thumbnail,
  });

  final String name;
  final String kindLabel;
  final int sizeBytes;

  /// True only when the file's text was really sent to the AI.
  final bool analyzed;
  final String? note;
  final Uint8List? thumbnail;
}

/// "12 KB", "3.4 MB".
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final double kb = bytes / 1024;
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
