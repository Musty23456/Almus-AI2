import 'dart:typed_data';

import 'package:almus_ai/attachments/attachment_models.dart';
import 'package:almus_ai/attachments/document_processor.dart';
import 'package:almus_ai/attachments/file_sniffer.dart';
import 'package:almus_ai/attachments/pdf_text_extractor.dart';
import 'package:almus_ai/attachments/text_extractors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_fixtures.dart';

const String hausa = 'Sannu! Ɓarna, ɗan ƙasa, ƴar uwa — 你好 🌍';

AttachmentException? failure(void Function() f) {
  try {
    f();
  } on AttachmentException catch (e) {
    return e;
  }
  return null;
}

void main() {
  group('text, markdown', () {
    test('UTF-8 text with Hausa characters is kept exactly', () {
      expect(extractPlainText(utf8Bytes(hausa)), hausa);
    });
    test('BOM and CRLF are normalised', () {
      expect(extractPlainText(Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8Bytes('a\r\nb')])), 'a\nb');
    });
    test('UTF-16 with BOM is decoded', () {
      final Uint8List b = Uint8List.fromList(<int>[0xFF, 0xFE, 0x61, 0, 0x62, 0]);
      expect(extractPlainText(b), 'ab');
    });
    test('invalid UTF-8 is refused instead of replaced', () {
      expect(failure(() => extractPlainText(Uint8List.fromList(<int>[0x61, 0xFF, 0xFE, 0x62]))), isNotNull);
    });
    test('empty and whitespace-only documents are refused', () {
      expect(failure(() => extractPlainText(utf8Bytes(''))), isNotNull);
      expect(failure(() => extractPlainText(utf8Bytes('  \n\t '))), isNotNull);
    });
  });

  group('CSV', () {
    test('quotes, commas, doubled quotes and line breaks inside cells', () {
      final List<List<String>> rows = parseCsvRows('a,"b,c","say ""hi""","x\ny"\n1,2,3,4\n', ',');
      expect(rows[0], <String>['a', 'b,c', 'say "hi"', 'x\ny']);
      expect(rows[1], <String>['1', '2', '3', '4']);
    });
    test('semicolon and tab delimiters are detected; summary line is added', () {
      final String out = extractCsv(utf8Bytes('Suna;Shekaru\nƁala;30\n'));
      expect(out, contains('CSV table: 2 rows, 2 columns'));
      expect(out, contains('Ɓala | 30'));
      expect(extractCsv(utf8Bytes('a\tb\n1\t2')), contains('a | b'));
    });
    test('unclosed quote is reported as damaged; empty files are refused', () {
      expect(failure(() => extractCsv(utf8Bytes('a,"b\n1,2'))), isNotNull);
      expect(failure(() => extractCsv(utf8Bytes('\n\n'))), isNotNull);
    });
    test('very long tables are capped', () {
      final String csv = List<String>.generate(50, (int i) => '$i,x').join('\n');
      expect(extractCsv(utf8Bytes(csv), maxRows: 10), contains('first 10 rows shown'));
    });
  });

  group('DOCX', () {
    test('paragraphs, entities, Hausa text', () {
      final String out = extractDocx(docxOf(<String>['Sannu &amp; barka', hausa, '']));
      expect(out, contains('Sannu & barka'));
      expect(out, contains(hausa));
    });
    test('a ZIP that is not a Word file is refused', () {
      expect(failure(() => extractDocx(zipOf(<String, String>{'x.txt': 'a'}))), isNotNull);
    });
    test('a Word file with no text is refused', () {
      expect(failure(() => extractDocx(docxOf(<String>[]))), isNotNull);
    });
    test('garbage bytes are refused', () {
      expect(failure(() => extractDocx(utf8Bytes('not a zip'))), isNotNull);
    });
  });

  group('XLSX', () {
    test('sheet name, shared strings, rich text, numbers, booleans, inline strings', () {
      final String out = extractXlsx(xlsxOf());
      expect(out, contains('Sheet: Sales & Costs'));
      expect(out, contains('Name | Total'));
      expect(out, contains('Ɓarna |  | 42'));
      expect(out, contains('inline | TRUE'));
    });
    test('workbook without values is refused', () {
      final Uint8List empty = zipOf(<String, String>{
        'xl/workbook.xml': '<workbook/>',
        'xl/worksheets/sheet1.xml': '<worksheet><sheetData/></worksheet>',
      });
      expect(failure(() => extractXlsx(empty)), isNotNull);
    });
  });

  group('PDF', () {
    const String page = 'BT /F1 12 Tf 72 700 Td (Hello PDF world) Tj 0 -14 Td (Second \\(line\\)) Tj ET';

    test('plain content stream: text, escapes and line breaks', () {
      final String out = extractPdfText(pdfOf(page));
      expect(out, contains('Hello PDF world'));
      expect(out, contains('Second (line)'));
      expect(out.split('\n').length, greaterThanOrEqualTo(2));
    });
    test('Flate-compressed content stream', () {
      expect(extractPdfText(pdfOf(page, flate: true)), contains('Hello PDF world'));
    });
    test('TJ arrays with kerning gaps become spaces', () {
      final String out = extractPdfText(pdfOf('BT /F1 12 Tf [(Hel)-20(lo) -400 (there)] TJ ET'));
      expect(out, contains('Hello there'));
    });
    test('hex strings with a ToUnicode map decode Hausa letters', () {
      final String out = extractPdfText(
        pdfOf('BT /F1 12 Tf <0001 0002 0001> Tj ET', type0: true, toUnicode: hausaCMap),
      );
      expect(out, contains('ɓiɓ'));
    });
    test('bfrange mappings work', () {
      final String out = extractPdfText(
        pdfOf('BT /F1 12 Tf <0010 0011 0012> Tj ET', type0: true, toUnicode: hausaCMap),
      );
      expect(out, contains('ABC'));
    });
    test('Type0 font without a Unicode map is reported, not guessed', () {
      final AttachmentException? e = failure(
        () => extractPdfText(pdfOf('BT /F1 12 Tf <0001 0002> Tj ET', type0: true)),
      );
      expect(e, isNotNull);
      expect(e!.message, contains('fonts'));
    });
    test('a PDF page without any text (scan) says so', () {
      final AttachmentException? e = failure(() => extractPdfText(pdfOf('q 100 0 0 100 0 0 cm /Im1 Do Q')));
      expect(e!.message, contains('No text was found'));
    });
    test('encrypted PDFs are refused with guidance', () {
      final AttachmentException? e = failure(() => extractPdfText(pdfOf(page, encrypted: true)));
      expect(e!.message, contains('password-protected'));
    });
    test('truncated and garbage PDFs fail cleanly', () {
      final Uint8List good = pdfOf(page);
      expect(failure(() => extractPdfText(Uint8List.sublistView(good, 0, 40))), isNotNull);
      expect(failure(() => extractPdfText(utf8Bytes('%PDF-1.4 garbage'))), isNotNull);
      expect(failure(() => extractPdfText(utf8Bytes('not a pdf'))), isNotNull);
    });
  });

  group('file sniffing and validation', () {
    final DocumentProcessor p = DocumentProcessor(useIsolate: false);

    test('real types are recognised from content', () {
      const FileSniffer s = FileSniffer();
      expect(s.sniff(pdfOf('BT ET')), SniffedType.pdf);
      expect(s.sniff(docxOf(<String>['a'])), SniffedType.docx);
      expect(s.sniff(xlsxOf()), SniffedType.xlsx);
      expect(s.sniff(pngBytes()), SniffedType.png);
      expect(s.sniff(jpegBytes()), SniffedType.jpeg);
      expect(s.sniff(utf8Bytes(hausa)), SniffedType.text);
      expect(s.sniff(Uint8List.fromList(<int>[1, 2, 0, 3])), SniffedType.binary);
      expect(s.sniff(Uint8List(0)), SniffedType.empty);
      expect(s.sniff(Uint8List.fromList(<int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0])), SniffedType.oleLegacy);
    });

    test('a renamed file is rejected: docx named .pdf', () {
      final AttachmentException? e = failure(() => p.classify('report.pdf', docxOf(<String>['a'])));
      expect(e!.message, contains('Word document'));
      expect(e.message, contains('Renaming'));
    });
    test('a renamed file is rejected: PDF named .txt, text named .docx, png named .pdf', () {
      expect(failure(() => p.classify('a.txt', pdfOf('BT ET')))!.message, contains('PDF'));
      expect(failure(() => p.classify('a.docx', utf8Bytes('hello')))!.message, contains('text file'));
      expect(failure(() => p.classify('a.pdf', pngBytes()))!.message, contains('PNG'));
    });
    test('unsupported types explain what is supported', () {
      for (final String name in <String>['a.exe', 'a.doc', 'a.xls', 'a.pptx', 'a.zip', 'a.heic', 'noext']) {
        final AttachmentException? e = failure(() => p.classify(name, utf8Bytes('x')));
        expect(e, isNotNull, reason: name);
        expect(e!.message, contains('Supported'), reason: name);
      }
    });
    test('oversized files are refused before reading', () {
      final AttachmentException? e = failure(() => DocumentProcessor.checkSize('big.pdf', kMaxDocumentBytes + 1));
      expect(e!.message, contains('limit'));
      expect(failure(() => DocumentProcessor.checkSize('big.png', kMaxImageBytes + 1)), isNotNull);
      expect(failure(() => DocumentProcessor.checkSize('ok.pdf', 1024)), isNull);
      expect(failure(() => DocumentProcessor.checkSize('empty.txt', 0)), isNotNull);
    });
    test('corrupted files: truncated PNG, broken DOCX zip, bad zip named xlsx', () {
      expect(failure(() => p.classify('a.png', truncatedPng()))!.message, contains('damaged'));
      expect(failure(() => p.classify('a.docx', zipOf(<String, String>{'x': 'y'})))!.message, contains('not a real'));
      expect(failure(() => p.classify('a.xlsx', Uint8List.fromList(<int>[0x50, 0x4B, 3, 4, 9, 9])))!.message, contains('damaged'));
    });
  });

  group('DocumentProcessor.process', () {
    final DocumentProcessor p = DocumentProcessor(useIsolate: false);

    test('text file: ready, kind, text', () async {
      final ChatAttachment a = await p.process(id: '1', name: 'notes.txt', bytes: utf8Bytes(hausa));
      expect(a.isReady, isTrue);
      expect(a.kind, AttachmentKind.text);
      expect(a.extractedText, hausa);
      expect(a.truncated, isFalse);
    });
    test('very long text is shortened and flagged', () async {
      final String long = List<String>.generate(5000, (int i) => 'line number $i').join('\n');
      final ChatAttachment a = await p.process(id: '1', name: 'long.md', bytes: utf8Bytes(long));
      expect(a.truncated, isTrue);
      expect(a.extractedText!.length, lessThanOrEqualTo(kMaxExtractedChars));
      expect(a.kind, AttachmentKind.markdown);
    });
    test('image: ready with a thumbnail and NO text (never pretends to be analysed)', () async {
      final ChatAttachment a = await p.process(id: '1', name: 'photo.png', bytes: pngBytes());
      expect(a.isImage, isTrue);
      expect(a.thumbnail, isNotNull);
      expect(a.extractedText, isNull);
    });
    test('empty document and failed parsing throw readable errors', () async {
      await expectLater(p.process(id: '1', name: 'e.txt', bytes: utf8Bytes('   ')), throwsA(isA<AttachmentException>()));
      await expectLater(p.process(id: '1', name: 'scan.pdf', bytes: pdfOf('q Q')), throwsA(isA<AttachmentException>()));
      await expectLater(p.process(id: '1', name: 'bad.csv', bytes: utf8Bytes('a,"b')), throwsA(isA<AttachmentException>()));
    });
    test('error messages never contain file content', () async {
      try {
        await p.process(id: '1', name: 'secret.csv', bytes: utf8Bytes('TOP-SECRET,"unclosed'));
        fail('should throw');
      } on AttachmentException catch (e) {
        expect(e.message.contains('TOP-SECRET'), isFalse);
      }
    });
    test('parsing in a background isolate gives the same result', () async {
      final DocumentProcessor iso = DocumentProcessor(useIsolate: true);
      final ChatAttachment a = await iso.process(id: '1', name: 'notes.txt', bytes: utf8Bytes(hausa));
      expect(a.extractedText, hausa);
      await expectLater(iso.process(id: '2', name: 'bad.docx', bytes: docxOf(<String>[])), throwsA(isA<AttachmentException>()));
    });
    test('file size text', () {
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(2048), '2.0 KB');
      expect(formatFileSize(3 * 1024 * 1024), '3.0 MB');
    });
  });
}
