import 'dart:isolate';
import 'dart:typed_data';

import 'attachment_models.dart';
import 'file_sniffer.dart';
import 'pdf_text_extractor.dart';
import 'text_extractors.dart';

/// Result of checking a file against its name: the real kind, or the reason
/// it cannot be used.
class Classification {
  const Classification(this.kind, this.sniffed);

  final AttachmentKind kind;
  final SniffedType sniffed;
}

/// Checks and reads attachments entirely on the phone. Nothing here touches
/// the network or a file path: it only sees bytes the user picked.
class DocumentProcessor {
  DocumentProcessor({this.useIsolate = true, FileSniffer? sniffer})
      : _sniffer = sniffer ?? const FileSniffer();

  /// Parse documents off the UI thread (turn off in tests).
  final bool useIsolate;
  final FileSniffer _sniffer;

  /// Size check that can run before the bytes are read.
  static void checkSize(String name, int sizeBytes) {
    final AttachmentKind? kind = AttachmentRules.kindForName(name);
    if (kind == null) {
      throw AttachmentException(AttachmentRules.unsupportedMessage(name));
    }
    if (sizeBytes <= 0) {
      throw AttachmentException('${_short(name)}: the file is empty.');
    }
    final int limit = kind.isImage ? kMaxImageBytes : kMaxDocumentBytes;
    if (sizeBytes > limit) {
      throw AttachmentException(
        '${_short(name)} is ${formatFileSize(sizeBytes)}. The limit is ${formatFileSize(limit)} per file.',
      );
    }
  }

  static String _short(String name) => name.length > 40 ? '${name.substring(0, 37)}…' : name;

  /// Decides what the file really is. Throws when the name and the content
  /// disagree (a renamed file is rejected) or the type is unsupported.
  Classification classify(String name, Uint8List bytes) {
    final String shown = _short(name);
    final AttachmentKind? byName = AttachmentRules.kindForName(name);
    if (byName == null) {
      throw AttachmentException(AttachmentRules.unsupportedMessage(name));
    }
    final SniffedType actual = _sniffer.sniff(bytes);
    if (actual == SniffedType.empty) {
      throw AttachmentException('$shown: the file is empty.');
    }

    bool ok;
    switch (byName) {
      case AttachmentKind.pdf:
        ok = actual == SniffedType.pdf;
        break;
      case AttachmentKind.docx:
        ok = actual == SniffedType.docx;
        break;
      case AttachmentKind.xlsx:
        ok = actual == SniffedType.xlsx;
        break;
      case AttachmentKind.image:
        ok = actual.isSupportedImage;
        break;
      case AttachmentKind.text:
      case AttachmentKind.markdown:
      case AttachmentKind.csv:
        ok = actual == SniffedType.text;
        break;
    }
    if (!ok) {
      final String ext = AttachmentRules.extensionOf(name);
      if (actual == SniffedType.zipOther && (byName == AttachmentKind.docx || byName == AttachmentKind.xlsx)) {
        throw AttachmentException(
          '$shown is damaged or is not a real .$ext file (it opens as a ZIP but has no ${byName == AttachmentKind.docx ? 'Word' : 'Excel'} content).',
        );
      }
      if (actual == SniffedType.binary || actual == SniffedType.text && byName.isImage) {
        throw AttachmentException(
          '$shown is named .$ext but its content is not a valid ${byName.label.toLowerCase()}. The file may be damaged. Renaming a file does not change what it is.',
        );
      }
      throw AttachmentException(
        '$shown is named .$ext but its content is ${actual.description}. Renaming a file does not convert it: open it in the right app and save or export it in the format you want.',
      );
    }
    if (byName.isImage && !_sniffer.imageLooksComplete(bytes, actual)) {
      throw AttachmentException('$shown looks damaged or cut off, so it was not attached.');
    }
    return Classification(byName, actual);
  }

  /// Checks the file and reads its text. The returned attachment is ready.
  Future<ChatAttachment> process({
    required String id,
    required String name,
    required Uint8List bytes,
  }) async {
    checkSize(name, bytes.length);
    final Classification c = classify(name, bytes);
    if (c.kind.isImage) {
      return ChatAttachment(
        id: id,
        name: name,
        sizeBytes: bytes.length,
        kind: AttachmentKind.image,
        status: AttachmentStatus.ready,
        thumbnail: bytes,
      );
    }

    final _Outcome outcome = useIsolate
        ? await Isolate.run<_Outcome>(() => _extract(c.kind, bytes))
        : _extract(c.kind, bytes);
    if (outcome.error != null) {
      throw AttachmentException('${_short(name)}: ${outcome.error}');
    }
    final String text = outcome.text ?? '';
    if (text.trim().isEmpty) {
      throw AttachmentException('${_short(name)}: no readable text was found in this file.');
    }
    final bool truncated = text.length > kMaxExtractedChars;
    return ChatAttachment(
      id: id,
      name: name,
      sizeBytes: bytes.length,
      kind: c.kind,
      status: AttachmentStatus.ready,
      extractedText: truncated ? _truncate(text, kMaxExtractedChars) : text,
      truncated: truncated,
    );
  }

  /// Shortens at a line break when possible.
  static String _truncate(String text, int max) {
    final String cut = text.substring(0, max);
    final int nl = cut.lastIndexOf('\n');
    return (nl > max ~/ 2 ? cut.substring(0, nl) : cut).trimRight();
  }
}

class _Outcome {
  const _Outcome({this.text, this.error});

  final String? text;
  final String? error;
}

/// Top-level so it can run in a background isolate. Errors are returned, not
/// thrown, because they must cross the isolate boundary safely.
_Outcome _extract(AttachmentKind kind, Uint8List bytes) {
  try {
    switch (kind) {
      case AttachmentKind.text:
      case AttachmentKind.markdown:
        return _Outcome(text: extractPlainText(bytes));
      case AttachmentKind.csv:
        return _Outcome(text: extractCsv(bytes));
      case AttachmentKind.docx:
        return _Outcome(text: extractDocx(bytes));
      case AttachmentKind.xlsx:
        return _Outcome(text: extractXlsx(bytes));
      case AttachmentKind.pdf:
        return _Outcome(text: extractPdfText(bytes));
      case AttachmentKind.image:
        return const _Outcome(error: 'images have no text to read.');
    }
  } on AttachmentException catch (e) {
    return _Outcome(error: e.message);
  } on Object {
    return const _Outcome(
      error: 'the file could not be read. It may be damaged or use a feature the app does not support.',
    );
  }
}
