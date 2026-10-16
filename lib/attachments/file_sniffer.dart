import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'attachment_models.dart';

/// What the bytes of a file really are.
enum SniffedType {
  empty,
  pdf,
  docx,
  xlsx,
  pptx,
  zipOther,
  png,
  jpeg,
  gif,
  webp,
  heic,
  oleLegacy,
  text,
  binary,
}

extension SniffedTypeText on SniffedType {
  /// Words for "this file is actually a ...".
  String get description {
    switch (this) {
      case SniffedType.empty:
        return 'empty';
      case SniffedType.pdf:
        return 'a PDF document';
      case SniffedType.docx:
        return 'a Word document (DOCX)';
      case SniffedType.xlsx:
        return 'an Excel spreadsheet (XLSX)';
      case SniffedType.pptx:
        return 'a PowerPoint presentation';
      case SniffedType.zipOther:
        return 'a ZIP archive';
      case SniffedType.png:
        return 'a PNG image';
      case SniffedType.jpeg:
        return 'a JPEG image';
      case SniffedType.gif:
        return 'a GIF image';
      case SniffedType.webp:
        return 'a WebP image';
      case SniffedType.heic:
        return 'a HEIC image';
      case SniffedType.oleLegacy:
        return 'an old Microsoft Office file (DOC/XLS/PPT)';
      case SniffedType.text:
        return 'a text file';
      case SniffedType.binary:
        return 'a binary file';
    }
  }

  bool get isSupportedImage =>
      this == SniffedType.png ||
      this == SniffedType.jpeg ||
      this == SniffedType.gif ||
      this == SniffedType.webp;
}

/// Looks at the first bytes (and, for ZIP-based formats, the entry names) to
/// find the real file type. Changing a file name changes nothing here.
class FileSniffer {
  const FileSniffer();

  SniffedType sniff(Uint8List b) {
    if (b.isEmpty) return SniffedType.empty;
    bool starts(List<int> sig, [int at = 0]) {
      if (b.length < at + sig.length) return false;
      for (int i = 0; i < sig.length; i++) {
        if (b[at + i] != sig[i]) return false;
      }
      return true;
    }

    // PDFs may have a few junk bytes before the header.
    final int probe = b.length < 1024 ? b.length : 1024;
    if (latin1.decode(b.sublist(0, probe)).contains('%PDF-')) {
      return SniffedType.pdf;
    }
    if (starts(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return SniffedType.png;
    }
    if (starts(const <int>[0xFF, 0xD8, 0xFF])) return SniffedType.jpeg;
    if (starts(const <int>[0x47, 0x49, 0x46, 0x38])) return SniffedType.gif;
    if (starts(const <int>[0x52, 0x49, 0x46, 0x46]) &&
        starts(const <int>[0x57, 0x45, 0x42, 0x50], 8)) {
      return SniffedType.webp;
    }
    if (starts(const <int>[0x66, 0x74, 0x79, 0x70], 4)) {
      final String brand = latin1.decode(b.sublist(8, b.length < 12 ? b.length : 12));
      if (brand.startsWith('hei') || brand.startsWith('mif1') || brand.startsWith('avif')) {
        return SniffedType.heic;
      }
    }
    if (starts(const <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
      return SniffedType.oleLegacy;
    }
    if (starts(const <int>[0x50, 0x4B, 0x03, 0x04]) ||
        starts(const <int>[0x50, 0x4B, 0x05, 0x06])) {
      return _sniffZip(b);
    }
    return looksLikeText(b) ? SniffedType.text : SniffedType.binary;
  }

  SniffedType _sniffZip(Uint8List b) {
    try {
      final Archive archive = ZipDecoder().decodeBytes(b);
      final Set<String> names = archive.files.map((ArchiveFile f) => f.name).toSet();
      if (names.contains('word/document.xml')) return SniffedType.docx;
      if (names.contains('xl/workbook.xml')) return SniffedType.xlsx;
      if (names.contains('ppt/presentation.xml')) return SniffedType.pptx;
      return SniffedType.zipOther;
    } on Object {
      // Looks like a ZIP but cannot be opened: damaged.
      return SniffedType.zipOther;
    }
  }

  /// True when [b] is readable text (UTF-8, optionally with a BOM, or UTF-16
  /// with a BOM) and contains no control bytes.
  bool looksLikeText(Uint8List b) {
    if (b.length >= 2 &&
        ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
      return true;
    }
    final int probe = b.length < 8192 ? b.length : 8192;
    for (int i = 0; i < probe; i++) {
      final int c = b[i];
      if (c == 0) return false;
      if (c < 9 || (c > 13 && c < 32)) {
        if (c != 27) return false;
      }
    }
    try {
      utf8.decode(b);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Cheap checks for a cut-off image (the preview would be broken).
  bool imageLooksComplete(Uint8List b, SniffedType type) {
    bool tailHas(List<int> sig, int window) {
      final int from = b.length > window ? b.length - window : 0;
      outer:
      for (int i = from; i <= b.length - sig.length; i++) {
        for (int k = 0; k < sig.length; k++) {
          if (b[i + k] != sig[k]) continue outer;
        }
        return true;
      }
      return false;
    }

    switch (type) {
      case SniffedType.png:
        return tailHas(const <int>[0x49, 0x45, 0x4E, 0x44], 24); // IEND
      case SniffedType.jpeg:
        int end = b.length;
        while (end > 2 && b[end - 1] == 0) {
          end--;
        }
        return b[end - 2] == 0xFF && b[end - 1] == 0xD9;
      case SniffedType.gif:
        return b.isNotEmpty && b.last == 0x3B;
      case SniffedType.webp:
        if (b.length < 12) return false;
        final int declared = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
        return declared + 8 <= b.length;
      default:
        return true;
    }
  }
}

/// File-name rules: which names are accepted and what each should contain.
class AttachmentRules {
  const AttachmentRules._();

  static const Map<String, AttachmentKind> _byExtension = <String, AttachmentKind>{
    'txt': AttachmentKind.text,
    'log': AttachmentKind.text,
    'json': AttachmentKind.text,
    'md': AttachmentKind.markdown,
    'markdown': AttachmentKind.markdown,
    'csv': AttachmentKind.csv,
    'tsv': AttachmentKind.csv,
    'pdf': AttachmentKind.pdf,
    'docx': AttachmentKind.docx,
    'xlsx': AttachmentKind.xlsx,
    'png': AttachmentKind.image,
    'jpg': AttachmentKind.image,
    'jpeg': AttachmentKind.image,
    'gif': AttachmentKind.image,
    'webp': AttachmentKind.image,
  };

  static const String supportedList =
      'images (PNG, JPG, GIF, WebP), PDF, Word (DOCX), Excel (XLSX), CSV/TSV, and text files (TXT, MD, LOG, JSON)';

  static String extensionOf(String name) {
    final String base = name.split('/').last;
    final int dot = base.lastIndexOf('.');
    return dot < 0 ? '' : base.substring(dot + 1).toLowerCase();
  }

  static AttachmentKind? kindForName(String name) => _byExtension[extensionOf(name)];

  /// A short reason for names that look familiar but are not supported.
  static String unsupportedMessage(String name) {
    final String ext = extensionOf(name);
    final String shown = name.length > 40 ? '${name.substring(0, 37)}…' : name;
    String why;
    switch (ext) {
      case 'doc':
      case 'xls':
      case 'ppt':
        why = 'old Microsoft Office files (.$ext) are not supported. Save it as DOCX or XLSX, or export it as PDF';
        break;
      case 'pptx':
      case 'odt':
      case 'ods':
      case 'rtf':
      case 'epub':
        why = '.$ext files are not supported yet. Export it as PDF or plain text';
        break;
      case 'heic':
      case 'heif':
      case 'avif':
      case 'bmp':
      case 'svg':
      case 'tiff':
        why = '.$ext images are not supported. Use PNG, JPG, GIF or WebP';
        break;
      case 'zip':
      case 'rar':
      case '7z':
        why = 'archives are not supported. Attach the files inside it one by one';
        break;
      case '':
        why = 'the file has no extension, so the app cannot tell what it should be';
        break;
      default:
        why = 'this file type (.$ext) is not supported';
    }
    return '$shown: $why. Supported: $supportedList.';
  }
}
