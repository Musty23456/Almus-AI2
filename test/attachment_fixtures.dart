import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A tiny but structurally complete PNG (signature ... IEND).
Uint8List pngBytes() => Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89,
      0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

/// A PNG cut off before its end.
Uint8List truncatedPng() => Uint8List.sublistView(pngBytes(), 0, 30);

Uint8List jpegBytes() => Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]);

Uint8List zipOf(Map<String, String> files) {
  final Archive a = Archive();
  files.forEach((String name, String text) {
    final List<int> data = utf8.encode(text);
    a.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Uint8List docxOf(List<String> paragraphs) {
  final String body = paragraphs
      .map((String p) => '<w:p><w:pPr><w:jc w:val="left"/></w:pPr><w:r><w:t xml:space="preserve">$p</w:t></w:r></w:p>')
      .join();
  return zipOf(<String, String>{
    '[Content_Types].xml': '<Types/>',
    'word/document.xml':
        '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>$body</w:body></w:document>',
  });
}

Uint8List xlsxOf() => zipOf(<String, String>{
      'xl/workbook.xml': '<workbook><sheets><sheet name="Sales &amp; Costs" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/sharedStrings.xml':
          '<sst><si><t>Name</t></si><si><t>Ɓarna</t></si><si><r><t>Tot</t></r><r><t>al</t></r></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
          '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>2</v></c></row>'
          '<row r="2"><c r="A2" t="s"><v>1</v></c><c r="C2"><v>42</v></c></row>'
          '<row r="3"><c r="A3" t="inlineStr"><is><t>inline</t></is></c><c r="B3" t="b"><v>1</v></c></row>'
          '</sheetData></worksheet>',
    });

/// Builds a small PDF. [content] is the page content stream.
Uint8List pdfOf(
  String content, {
  bool flate = false,
  String? toUnicode,
  bool type0 = false,
  bool encrypted = false,
  bool objectStream = false,
}) {
  final List<int> stream = flate ? zlib.encode(utf8.encode(content)) : latin1.encode(content);
  final StringBuffer head = StringBuffer('%PDF-1.5\n');
  head.write('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  head.write('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  head.write('3 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n');
  final BytesBuilder b = BytesBuilder();
  b.add(latin1.encode(head.toString()));
  b.add(latin1.encode('4 0 obj\n<< /Length ${stream.length}${flate ? ' /Filter /FlateDecode' : ''} >>\nstream\n'));
  b.add(stream);
  b.add(latin1.encode('\nendstream\nendobj\n'));
  final String font = type0
      ? '<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H${toUnicode != null ? ' /ToUnicode 6 0 R' : ''} >>'
      : '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
  b.add(latin1.encode('5 0 obj\n$font\nendobj\n'));
  if (toUnicode != null) {
    final List<int> cm = latin1.encode(toUnicode);
    b.add(latin1.encode('6 0 obj\n<< /Length ${cm.length} >>\nstream\n'));
    b.add(cm);
    b.add(latin1.encode('\nendstream\nendobj\n'));
  }
  b.add(latin1.encode('trailer\n<< /Root 1 0 R${encrypted ? ' /Encrypt 9 0 R' : ''} >>\n%%EOF\n'));
  return b.toBytes();
}

const String hausaCMap = '''
/CIDInit /ProcSet findresource begin 12 dict begin begincmap
1 begincodespacerange <0000> <FFFF> endcodespacerange
2 beginbfchar
<0001> <0253>
<0002> <0069>
endbfchar
1 beginbfrange
<0010> <0012> <0041>
endbfrange
endcmap end end
''';
