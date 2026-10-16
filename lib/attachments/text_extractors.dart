import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'attachment_models.dart';

/// Decodes UTF-8 (with or without BOM) or UTF-16 (with BOM) and normalises
/// line endings. Never silently replaces bad bytes.
String decodeText(Uint8List bytes) {
  try {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes, 2, littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes, 2, littleEndian: false);
    }
    String text = utf8.decode(bytes);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  } on FormatException {
    throw const AttachmentException(
      'The file is not valid UTF-8 text, so some characters could be lost. Save it as UTF-8 and try again.',
    );
  }
}

String _utf16(Uint8List b, int start, {required bool littleEndian}) {
  final List<int> units = <int>[];
  for (int i = start; i + 1 < b.length; i += 2) {
    units.add(littleEndian ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
  }
  return String.fromCharCodes(units).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// Plain text and Markdown: the text itself.
String extractPlainText(Uint8List bytes) {
  final String text = decodeText(bytes).trim();
  if (text.isEmpty) {
    throw const AttachmentException('The file is empty: it contains no text.');
  }
  return text;
}

// ----------------------------------------------------------------------- CSV

/// Splits CSV/TSV text into rows (RFC 4180 quoting, quoted line breaks).
List<List<String>> parseCsvRows(String text, String delimiter) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;
  bool cellStarted = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
    cellStarted = false;
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"' && !cellStarted) {
      quoted = true;
      cellStarted = true;
    } else if (c == delimiter) {
      endCell();
    } else if (c == '\n') {
      endRow();
    } else {
      cell.write(c);
      cellStarted = true;
    }
  }
  if (quoted) {
    throw const AttachmentException(
      'The CSV file is damaged: a quoted value is never closed.',
    );
  }
  if (cellStarted || cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

String _detectDelimiter(String text) {
  final List<String> lines = text.split('\n').where((String l) => l.trim().isNotEmpty).take(5).toList();
  String best = ',';
  int bestScore = -1;
  for (final String d in <String>[',', ';', '\t', '|']) {
    final int score = lines.fold<int>(0, (int s, String l) => s + d.allMatches(l).length);
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/// CSV/TSV as readable text: a summary line, then one row per line with
/// cells separated by " | ".
String extractCsv(Uint8List bytes, {int maxRows = 2000}) {
  final String text = decodeText(bytes);
  if (text.trim().isEmpty) {
    throw const AttachmentException('The file is empty: it contains no rows.');
  }
  final List<List<String>> rows = parseCsvRows(text, _detectDelimiter(text))
      .where((List<String> r) => r.any((String c) => c.trim().isNotEmpty))
      .toList();
  if (rows.isEmpty) {
    throw const AttachmentException('The file is empty: it contains no rows.');
  }
  final int columns = rows.fold<int>(0, (int m, List<String> r) => r.length > m ? r.length : m);
  final StringBuffer b = StringBuffer(
    'CSV table: ${rows.length} rows, $columns columns'
    '${rows.length > maxRows ? ' (first $maxRows rows shown)' : ''}\n',
  );
  for (final List<String> r in rows.take(maxRows)) {
    b.writeln(r.map((String c) => c.replaceAll('\n', ' ').trim()).join(' | '));
  }
  return b.toString().trimRight();
}

// ----------------------------------------------------------------- XML helpers

String decodeXmlEntities(String s) {
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'), (Match m) {
    final String e = m.group(1)!;
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final int? code = e.startsWith('#x')
        ? int.tryParse(e.substring(2), radix: 16)
        : int.tryParse(e.substring(1));
    if (code == null || code <= 0 || code > 0x10FFFF) return '';
    return String.fromCharCode(code);
  });
}

Archive _openZip(Uint8List bytes, String what) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw AttachmentException('The $what file is damaged and cannot be opened.');
  }
}

String _entryText(Archive archive, String name) {
  final ArchiveFile? f = archive.findFile(name);
  if (f == null) {
    throw const AttachmentException('The file is damaged: a required part is missing.');
  }
  try {
    return utf8.decode(f.content as List<int>, allowMalformed: true);
  } on Object {
    throw const AttachmentException('The file is damaged: a part could not be unpacked.');
  }
}

// ----------------------------------------------------------------------- DOCX

/// Text of a Word (.docx) document: paragraphs, tabs and line breaks.
String extractDocx(Uint8List bytes) {
  final Archive archive = _openZip(bytes, 'Word');
  final String xml = _entryText(archive, 'word/document.xml');
  final RegExp paragraph = RegExp(r'<w:p[\s>][\s\S]*?</w:p>');
  final RegExp token = RegExp(
    r'<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>|<w:tab\s*/>|<w:br\s*/>|<w:cr\s*/>',
  );
  final List<String> lines = <String>[];
  for (final Match p in paragraph.allMatches(xml)) {
    final StringBuffer line = StringBuffer();
    for (final Match t in token.allMatches(p.group(0)!)) {
      final String whole = t.group(0)!;
      if (whole.startsWith('<w:tab')) {
        line.write('\t');
      } else if (whole.startsWith('<w:br') || whole.startsWith('<w:cr')) {
        line.write('\n');
      } else {
        line.write(decodeXmlEntities(t.group(1) ?? ''));
      }
    }
    lines.add(line.toString().trimRight());
  }
  final String text = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (text.isEmpty) {
    throw const AttachmentException('The Word document contains no text.');
  }
  return text;
}

// ----------------------------------------------------------------------- XLSX

int _columnIndex(String ref) {
  int n = 0;
  for (final int u in ref.codeUnits) {
    if (u >= 65 && u <= 90) {
      n = n * 26 + (u - 64);
    } else if (u >= 97 && u <= 122) {
      n = n * 26 + (u - 96);
    } else {
      break;
    }
  }
  return n == 0 ? 0 : n - 1;
}

String _stringItemText(String xml) {
  final String cleaned = xml.replaceAll(RegExp(r'<rPh[\s\S]*?</rPh>'), '');
  final StringBuffer b = StringBuffer();
  for (final Match m in RegExp(r'<t(?:\s[^>]*)?>([\s\S]*?)</t>').allMatches(cleaned)) {
    b.write(decodeXmlEntities(m.group(1) ?? ''));
  }
  return b.toString();
}

/// Cell values of an Excel (.xlsx) workbook, sheet by sheet, rows as
/// " | " separated lines. Formulas show their last saved result; dates appear
/// as the serial numbers Excel stores.
String extractXlsx(Uint8List bytes, {int maxRowsPerSheet = 1000}) {
  final Archive archive = _openZip(bytes, 'Excel');
  if (archive.findFile('xl/workbook.xml') == null) {
    throw const AttachmentException('The file is damaged: it has no workbook.');
  }
  final List<String> shared = <String>[];
  final ArchiveFile? sharedFile = archive.findFile('xl/sharedStrings.xml');
  if (sharedFile != null) {
    final String xml = utf8.decode(sharedFile.content as List<int>, allowMalformed: true);
    for (final Match m in RegExp(r'<si[\s>][\s\S]*?</si>|<si/>').allMatches(xml)) {
      shared.add(_stringItemText(m.group(0)!));
    }
  }
  final String workbook = _entryText(archive, 'xl/workbook.xml');
  final List<String> names = RegExp(r'<sheet\s[^>]*?name="([^"]*)"')
      .allMatches(workbook)
      .map((Match m) => decodeXmlEntities(m.group(1)!))
      .toList();

  final List<ArchiveFile> sheets = archive.files
      .where((ArchiveFile f) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((ArchiveFile a, ArchiveFile b) {
      int n(ArchiveFile f) => int.parse(RegExp(r'(\d+)\.xml$').firstMatch(f.name)!.group(1)!);
      return n(a).compareTo(n(b));
    });

  final StringBuffer out = StringBuffer();
  int cells = 0;
  for (int s = 0; s < sheets.length; s++) {
    final String xml = utf8.decode(sheets[s].content as List<int>, allowMalformed: true);
    final String title = s < names.length ? names[s] : 'Sheet ${s + 1}';
    final List<String> lines = <String>[];
    int rowCount = 0;
    for (final Match row in RegExp(r'<row[\s>][\s\S]*?</row>').allMatches(xml)) {
      final Map<int, String> values = <int, String>{};
      for (final Match c in RegExp(r'<c\s([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(row.group(0)!)) {
        final String attrs = c.group(1) ?? '';
        final String inner = c.group(2) ?? '';
        final String ref = RegExp(r'\br="([A-Za-z]+)\d+"').firstMatch(attrs)?.group(1) ?? '';
        final String type = RegExp(r'\bt="([^"]*)"').firstMatch(attrs)?.group(1) ?? 'n';
        String value = '';
        if (type == 'inlineStr') {
          value = _stringItemText(inner);
        } else {
          final String raw = decodeXmlEntities(
            RegExp(r'<v>([\s\S]*?)</v>').firstMatch(inner)?.group(1) ?? '',
          );
          if (type == 's') {
            final int? idx = int.tryParse(raw);
            value = (idx != null && idx >= 0 && idx < shared.length) ? shared[idx] : '';
          } else if (type == 'b') {
            value = raw == '1' ? 'TRUE' : 'FALSE';
          } else {
            value = raw;
          }
        }
        if (value.trim().isNotEmpty) {
          values[_columnIndex(ref)] = value.replaceAll('\n', ' ').trim();
          cells++;
        }
      }
      if (values.isEmpty) continue;
      rowCount++;
      if (rowCount > maxRowsPerSheet) continue;
      final int last = values.keys.reduce((int a, int b) => a > b ? a : b);
      lines.add(<String>[for (int i = 0; i <= last; i++) values[i] ?? ''].join(' | '));
    }
    if (lines.isEmpty) continue;
    out.writeln('Sheet: $title ($rowCount rows${rowCount > maxRowsPerSheet ? ', first $maxRowsPerSheet shown' : ''})');
    out.writeln(lines.join('\n'));
    out.writeln();
  }
  if (cells == 0) {
    throw const AttachmentException('The spreadsheet contains no values.');
  }
  return out.toString().trimRight();
}
