import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'attachment_models.dart';

/// Extracts the text of a PDF without any plugin.
///
/// Works for ordinary text PDFs: page tree, Flate-compressed content streams,
/// object streams and embedded "ToUnicode" font maps. It does NOT do OCR, so
/// scanned or image-only PDFs yield nothing, and it cannot open encrypted
/// PDFs, LZW/ASCII85-compressed streams, or fonts without a Unicode map.
/// Anything it cannot read produces a clear [AttachmentException] rather than
/// guessed text.
String extractPdfText(Uint8List bytes, {int maxPages = 200}) {
  final _Pdf pdf = _Pdf(bytes);
  return pdf.extract(maxPages);
}

class _Obj {
  _Obj(this.num, this.dict, this.stream);

  final int num;
  final String dict;
  final Uint8List? stream;
}

class _CMap {
  final Map<int, String> map = <int, String>{};
  int codeBytes = 1;
}

class _Font {
  _Font({this.cmap, this.undecodable = false});

  final _CMap? cmap;
  final bool undecodable;
}

class _Pdf {
  _Pdf(this.bytes) : source = latin1.decode(bytes);

  final Uint8List bytes;
  final String source;
  final Map<int, _Obj> objects = <int, _Obj>{};
  final Map<int, _Font> fonts = <int, _Font>{};
  int undecodableChars = 0;

  static final RegExp _objHeader = RegExp(r'(\d+)\s+(\d+)\s+obj\b');
  static final RegExp _streamStart = RegExp(r'>>\s*stream\r?\n');

  String extract(int maxPages) {
    if (!source.contains('%PDF-')) {
      throw const AttachmentException('This is not a valid PDF file.');
    }
    if (source.contains('/Encrypt')) {
      throw const AttachmentException(
        'This PDF is password-protected or encrypted, so its text cannot be read. Remove the protection and try again.',
      );
    }
    _scanObjects();
    if (objects.isEmpty) {
      throw const AttachmentException(
        'The PDF is damaged or incomplete: no objects could be read.',
      );
    }
    _loadFonts();
    final List<int> pages = _pageOrder();
    if (pages.isEmpty) {
      throw const AttachmentException('The PDF has no pages that can be read.');
    }
    final StringBuffer out = StringBuffer();
    int count = 0;
    for (final int pageNum in pages) {
      if (count++ >= maxPages) break;
      try {
        final String text = _pageText(objects[pageNum]!);
        if (text.trim().isNotEmpty) {
          out.writeln(text.trim());
          out.writeln();
        }
      } on Object {
        // One unreadable page must not hide the others.
      }
    }
    final String result = out
        .toString()
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    final int letters = RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(result).length;
    if (letters < 3) {
      throw AttachmentException(
        undecodableChars > 0
            ? 'The PDF uses fonts this app cannot decode, so no text could be read. Export it as text or DOCX instead.'
            : 'No text was found in this PDF. It may be a scan or a picture of text (the app does not do OCR). Use a PDF with selectable text.',
      );
    }
    return result;
  }

  // ------------------------------------------------------------ objects

  void _scanObjects() {
    int pos = 0;
    while (true) {
      final Match? header = _objHeader.matchAsPrefix(source, pos) ??
          _objHeader.allMatches(source, pos).firstOrNull;
      if (header == null) break;
      final int num = int.parse(header.group(1)!);
      final int bodyStart = header.end;
      final Match? sm = _streamStart.allMatches(source, bodyStart).firstOrNull;
      final int endObjProbe = source.indexOf('endobj', bodyStart);
      String dict;
      Uint8List? stream;
      int next;
      if (sm != null && (endObjProbe < 0 || sm.start < endObjProbe)) {
        dict = source.substring(bodyStart, sm.start + 2);
        final int dataStart = sm.end;
        int dataEnd = source.indexOf('endstream', dataStart);
        if (dataEnd < 0) dataEnd = bytes.length;
        int e = dataEnd;
        if (e > dataStart && bytes[e - 1] == 0x0A) e--;
        if (e > dataStart && bytes[e - 1] == 0x0D) e--;
        stream = Uint8List.sublistView(bytes, dataStart, e);
        final int objEnd = source.indexOf('endobj', dataEnd);
        next = objEnd < 0 ? dataEnd : objEnd + 6;
      } else {
        final int objEnd = endObjProbe < 0 ? source.length : endObjProbe;
        dict = source.substring(bodyStart, objEnd);
        next = objEnd + 6;
      }
      final _Obj obj = _Obj(num, dict, stream);
      objects[num] = obj;
      if (RegExp(r'/Type\s*/ObjStm').hasMatch(dict) && stream != null) {
        _expandObjectStream(obj);
      }
      pos = next;
      if (pos >= source.length) break;
    }
  }

  void _expandObjectStream(_Obj obj) {
    final Uint8List? data = _decode(obj);
    if (data == null) return;
    final String text = latin1.decode(data);
    final int? n = _intAfter(obj.dict, 'N');
    final int? first = _intAfter(obj.dict, 'First');
    if (n == null || first == null || n <= 0 || n > 100000) return;
    final List<int> numbers = RegExp(r'\d+')
        .allMatches(text.substring(0, first.clamp(0, text.length)))
        .map((Match m) => int.parse(m.group(0)!))
        .toList();
    for (int i = 0; i < n && 2 * i + 1 < numbers.length; i++) {
      final int objNum = numbers[2 * i];
      final int start = first + numbers[2 * i + 1];
      final int end = (2 * i + 3 < numbers.length)
          ? first + numbers[2 * i + 3]
          : text.length;
      if (start < 0 || start > text.length || end > text.length || end < start) continue;
      objects.putIfAbsent(objNum, () => _Obj(objNum, text.substring(start, end), null));
    }
  }

  int? _intAfter(String dict, String key) {
    final Match? m = RegExp('/$key\\s+(\\d+)').firstMatch(dict);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Decompresses a stream. Returns null for filters this reader lacks.
  Uint8List? _decode(_Obj obj) {
    final Uint8List? raw = obj.stream;
    if (raw == null) return null;
    final String d = obj.dict;
    final bool flate = d.contains('/FlateDecode') || RegExp(r'/Filter\s*/Fl\b').hasMatch(d);
    final bool other = RegExp(
      r'/(LZWDecode|ASCII85Decode|ASCIIHexDecode|RunLengthDecode|DCTDecode|CCITTFaxDecode|JBIG2Decode|JPXDecode)',
    ).hasMatch(d);
    if (other) return null;
    if (!flate) return raw;
    try {
      return Uint8List.fromList(zlib.decode(raw));
    } on Object {
      return null;
    }
  }

  // -------------------------------------------------------------- fonts

  void _loadFonts() {
    for (final _Obj o in objects.values) {
      if (!RegExp(r'/Type\s*/Font(?![A-Za-z])').hasMatch(o.dict)) continue;
      final Match? tu = RegExp(r'/ToUnicode\s+(\d+)\s+\d+\s+R').firstMatch(o.dict);
      _Font font;
      if (tu != null) {
        final _Obj? cm = objects[int.parse(tu.group(1)!)];
        final Uint8List? data = cm == null ? null : _decode(cm);
        font = data == null
            ? _Font(undecodable: true)
            : _Font(cmap: _parseCMap(latin1.decode(data)));
      } else if (o.dict.contains('/Type0') || o.dict.contains('Identity-H')) {
        font = _Font(undecodable: true);
      } else {
        font = _Font();
      }
      fonts[o.num] = font;
    }
  }

  String _utf16Hex(String hex) {
    final String h = hex.replaceAll(RegExp(r'\s'), '');
    final List<int> units = <int>[];
    for (int i = 0; i + 3 < h.length + 1 && i + 4 <= h.length; i += 4) {
      units.add(int.parse(h.substring(i, i + 4), radix: 16));
    }
    if (h.length == 2) units.add(int.parse(h, radix: 16));
    return String.fromCharCodes(units);
  }

  _CMap _parseCMap(String text) {
    final _CMap cmap = _CMap();
    final Match? cs = RegExp(r'begincodespacerange\s*<([0-9A-Fa-f]+)>').firstMatch(text);
    if (cs != null) cmap.codeBytes = (cs.group(1)!.length / 2).ceil().clamp(1, 4);
    for (final Match block
        in RegExp(r'beginbfchar([\s\S]*?)endbfchar').allMatches(text)) {
      for (final Match m in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>')
          .allMatches(block.group(1)!)) {
        cmap.map[int.parse(m.group(1)!, radix: 16)] = _utf16Hex(m.group(2)!);
      }
    }
    for (final Match block
        in RegExp(r'beginbfrange([\s\S]*?)endbfrange').allMatches(text)) {
      for (final Match m in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])',
      ).allMatches(block.group(1)!)) {
        final int lo = int.parse(m.group(1)!, radix: 16);
        final int hi = int.parse(m.group(2)!, radix: 16);
        if (hi < lo || hi - lo > 65535) continue;
        final String dst = m.group(3)!;
        if (dst.startsWith('[')) {
          final List<Match> items = RegExp(r'<([0-9A-Fa-f]*)>').allMatches(dst).toList();
          for (int i = 0; i <= hi - lo && i < items.length; i++) {
            cmap.map[lo + i] = _utf16Hex(items[i].group(1)!);
          }
        } else {
          final String base = _utf16Hex(dst.substring(1, dst.length - 1));
          if (base.isEmpty) continue;
          for (int i = 0; i <= hi - lo; i++) {
            final List<int> units = base.codeUnits.toList();
            units[units.length - 1] += i;
            cmap.map[lo + i] = String.fromCharCodes(units);
          }
        }
      }
    }
    return cmap;
  }

  // -------------------------------------------------------------- pages

  List<int> _pageOrder() {
    final List<int> ordered = <int>[];
    final Set<int> seen = <int>{};
    void walk(int num, int depth) {
      if (depth > 20 || !seen.add(num)) return;
      final _Obj? o = objects[num];
      if (o == null) return;
      if (RegExp(r'/Type\s*/Page(?![A-Za-z])').hasMatch(o.dict)) {
        ordered.add(num);
        return;
      }
      final Match? kids = RegExp(r'/Kids\s*\[([^\]]*)\]').firstMatch(o.dict);
      if (kids == null) return;
      for (final Match r in RegExp(r'(\d+)\s+\d+\s+R').allMatches(kids.group(1)!)) {
        walk(int.parse(r.group(1)!), depth + 1);
      }
    }

    final Match? root = RegExp(r'/Root\s+(\d+)\s+\d+\s+R').firstMatch(source);
    if (root != null) {
      final _Obj? catalog = objects[int.parse(root.group(1)!)];
      final Match? pages = catalog == null
          ? null
          : RegExp(r'/Pages\s+(\d+)\s+\d+\s+R').firstMatch(catalog.dict);
      if (pages != null) walk(int.parse(pages.group(1)!), 0);
    }
    if (ordered.isNotEmpty) return ordered;
    // Fallback: every page object, in file order.
    final List<int> all = objects.values
        .where((_Obj o) => RegExp(r'/Type\s*/Page(?![A-Za-z])').hasMatch(o.dict))
        .map((_Obj o) => o.num)
        .toList()
      ..sort();
    return all;
  }

  /// Returns the dictionary text stored under [key] (inline or referenced).
  String? _dictValue(String dict, String key) {
    final Match? m = RegExp('/$key(?![A-Za-z])\\s*').firstMatch(dict);
    if (m == null) return null;
    final String rest = dict.substring(m.end);
    final Match? ref = RegExp(r'^(\d+)\s+\d+\s+R').firstMatch(rest);
    if (ref != null) return objects[int.parse(ref.group(1)!)]?.dict;
    if (rest.startsWith('<<')) return _balanced(rest);
    return null;
  }

  String _balanced(String s) {
    int depth = 0;
    for (int i = 0; i + 1 < s.length; i++) {
      if (s[i] == '<' && s[i + 1] == '<') {
        depth++;
        i++;
      } else if (s[i] == '>' && s[i + 1] == '>') {
        depth--;
        i++;
        if (depth == 0) return s.substring(0, i + 1);
      }
    }
    return s;
  }

  Map<String, _Font> _fontsFor(_Obj page) {
    String? resources;
    _Obj? node = page;
    for (int up = 0; up < 6 && node != null && resources == null; up++) {
      resources = _dictValue(node.dict, 'Resources');
      final Match? parent = RegExp(r'/Parent\s+(\d+)\s+\d+\s+R').firstMatch(node.dict);
      node = parent == null ? null : objects[int.parse(parent.group(1)!)];
    }
    final Map<String, _Font> result = <String, _Font>{};
    if (resources == null) return result;
    final String? fontDict = _dictValue(resources, 'Font');
    if (fontDict == null) return result;
    for (final Match m in RegExp(r'/([^\s/<>\[\]()]+)\s+(\d+)\s+\d+\s+R').allMatches(fontDict)) {
      final _Font? f = fonts[int.parse(m.group(2)!)];
      if (f != null) result[m.group(1)!] = f;
    }
    return result;
  }

  String _pageText(_Obj page) {
    final Map<String, _Font> pageFonts = _fontsFor(page);
    final StringBuffer content = StringBuffer();
    final Match? single = RegExp(r'/Contents\s+(\d+)\s+\d+\s+R').firstMatch(page.dict);
    final Match? array = RegExp(r'/Contents\s*\[([^\]]*)\]').firstMatch(page.dict);
    final List<int> refs = <int>[];
    if (single != null) {
      refs.add(int.parse(single.group(1)!));
    } else if (array != null) {
      for (final Match r in RegExp(r'(\d+)\s+\d+\s+R').allMatches(array.group(1)!)) {
        refs.add(int.parse(r.group(1)!));
      }
    }
    for (final int r in refs) {
      final _Obj? o = objects[r];
      final Uint8List? data = o == null ? null : _decode(o);
      if (data != null) {
        content.write(latin1.decode(data));
        content.write('\n');
      }
    }
    return _interpret(content.toString(), pageFonts);
  }

  // ----------------------------------------------------- content stream

  String _interpret(String s, Map<String, _Font> pageFonts) => _run(s, pageFonts);

  // The tokenizer is written as a separate method with explicit position
  // state so the string readers can share it.
  late String _s;
  int _i = 0;

  String _run(String s, Map<String, _Font> pageFonts) {
    _s = s;
    _i = 0;
    final int n = s.length;
    final StringBuffer out = StringBuffer();
    final List<Object> operands = <Object>[];
    _Font? font;
    double? lastY;

    void newline() {
      final String t = out.toString();
      if (t.isNotEmpty && !t.endsWith('\n')) out.write('\n');
    }

    void space() {
      final String t = out.toString();
      if (t.isNotEmpty && !t.endsWith(' ') && !t.endsWith('\n')) out.write(' ');
    }

    bool isSpace(int c) => c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0;

    while (_i < n) {
      final int c = s.codeUnitAt(_i);
      if (isSpace(c)) {
        _i++;
      } else if (c == 0x25) {
        while (_i < n && s.codeUnitAt(_i) != 10 && s.codeUnitAt(_i) != 13) {
          _i++;
        }
      } else if (c == 0x28) {
        operands.add(_readLiteral());
      } else if (c == 0x3C) {
        if (_i + 1 < n && s.codeUnitAt(_i + 1) == 0x3C) {
          _skipDict();
          operands.add('<<>>');
        } else {
          operands.add(_readHex());
        }
      } else if (c == 0x5B) {
        _i++;
        operands.add(_readArray());
      } else if (c == 0x2F) {
        final int start = ++_i;
        while (_i < n && !isSpace(s.codeUnitAt(_i)) && !'()<>[]{}/%'.contains(s[_i])) {
          _i++;
        }
        operands.add('/${s.substring(start, _i)}');
      } else {
        final int start = _i;
        while (_i < n && !isSpace(s.codeUnitAt(_i)) && !'()<>[]{}/%'.contains(s[_i])) {
          _i++;
        }
        if (_i == start) {
          _i++;
          continue;
        }
        final String token = s.substring(start, _i);
        final double? number = double.tryParse(token);
        if (number != null) {
          operands.add(number);
          continue;
        }
        // An operator.
        switch (token) {
          case 'BI':
            final int ei = s.indexOf(RegExp(r'\sEI(\s|$)'), _i);
            _i = ei < 0 ? n : ei + 3;
            break;
          case 'Tf':
            if (operands.length >= 2 && operands[operands.length - 2] is String) {
              final String name = (operands[operands.length - 2] as String).substring(1);
              font = pageFonts[name];
            }
            break;
          case 'Tj':
            if (operands.isNotEmpty && operands.last is List<int>) {
              out.write(_decodeString(operands.last as List<int>, font));
            }
            break;
          case "'":
          case '"':
            newline();
            if (operands.isNotEmpty && operands.last is List<int>) {
              out.write(_decodeString(operands.last as List<int>, font));
            }
            break;
          case 'TJ':
            if (operands.isNotEmpty && operands.last is List<Object>) {
              for (final Object item in operands.last as List<Object>) {
                if (item is List<int>) {
                  out.write(_decodeString(item, font));
                } else if (item is double && item < -250) {
                  space();
                }
              }
            }
            break;
          case 'Td':
          case 'TD':
            if (operands.length >= 2 && operands[operands.length - 1] is double && operands[operands.length - 2] is double) {
              final double ty = operands[operands.length - 1] as double;
              final double tx = operands[operands.length - 2] as double;
              if (ty.abs() > 0.1) {
                newline();
              } else if (tx > 0) {
                space();
              }
            }
            break;
          case 'Tm':
            if (operands.length >= 6 && operands.last is double) {
              final double y = operands.last as double;
              if (lastY != null && (y - lastY).abs() > 1) {
                newline();
              } else if (lastY != null) {
                space();
              }
              lastY = y;
            }
            break;
          case 'T*':
            newline();
            break;
          case 'ET':
            newline();
            lastY = null;
            break;
        }
        operands.clear();
      }
    }
    return out.toString();
  }

  List<Object> _readArray() {
    final String s = _s;
    final int n = s.length;
    final List<Object> items = <Object>[];
    bool isSpace(int c) => c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0;
    while (_i < n) {
      final int c = s.codeUnitAt(_i);
      if (c == 0x5D) {
        _i++;
        break;
      }
      if (isSpace(c)) {
        _i++;
      } else if (c == 0x28) {
        items.add(_readLiteral());
      } else if (c == 0x3C && _i + 1 < n && s.codeUnitAt(_i + 1) != 0x3C) {
        items.add(_readHex());
      } else {
        final int start = _i;
        while (_i < n && !isSpace(s.codeUnitAt(_i)) && s.codeUnitAt(_i) != 0x5D && s.codeUnitAt(_i) != 0x28 && s.codeUnitAt(_i) != 0x3C) {
          _i++;
        }
        final double? v = double.tryParse(s.substring(start, _i));
        if (v != null) items.add(v);
        if (_i == start) _i++;
      }
    }
    return items;
  }

  void _skipDict() {
    final String s = _s;
    int depth = 0;
    while (_i + 1 < s.length) {
      if (s[_i] == '<' && s[_i + 1] == '<') {
        depth++;
        _i += 2;
      } else if (s[_i] == '>' && s[_i + 1] == '>') {
        depth--;
        _i += 2;
        if (depth <= 0) return;
      } else {
        _i++;
      }
    }
    _i = s.length;
  }

  List<int> _readLiteral() {
    final String s = _s;
    final List<int> out = <int>[];
    int depth = 0;
    _i++; // '('
    depth = 1;
    while (_i < s.length) {
      final int c = s.codeUnitAt(_i++);
      if (c == 0x5C) {
        if (_i >= s.length) break;
        final int e = s.codeUnitAt(_i++);
        switch (e) {
          case 0x6E:
            out.add(10);
            break;
          case 0x72:
            out.add(13);
            break;
          case 0x74:
            out.add(9);
            break;
          case 0x62:
            out.add(8);
            break;
          case 0x66:
            out.add(12);
            break;
          case 0x0D:
            if (_i < s.length && s.codeUnitAt(_i) == 0x0A) _i++;
            break;
          case 0x0A:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              int v = e - 0x30;
              for (int k = 0; k < 2 && _i < s.length; k++) {
                final int d = s.codeUnitAt(_i);
                if (d >= 0x30 && d <= 0x37) {
                  v = v * 8 + (d - 0x30);
                  _i++;
                } else {
                  break;
                }
              }
              out.add(v & 0xFF);
            } else {
              out.add(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
      } else {
        out.add(c);
      }
    }
    return out;
  }

  List<int> _readHex() {
    final String s = _s;
    _i++; // '<'
    final StringBuffer hex = StringBuffer();
    while (_i < s.length && s.codeUnitAt(_i) != 0x3E) {
      final String ch = s[_i++];
      if (RegExp(r'[0-9A-Fa-f]').hasMatch(ch)) hex.write(ch);
    }
    if (_i < s.length) _i++; // '>'
    String h = hex.toString();
    if (h.length.isOdd) h = '${h}0';
    return <int>[
      for (int k = 0; k < h.length; k += 2) int.parse(h.substring(k, k + 2), radix: 16),
    ];
  }

  String _decodeString(List<int> data, _Font? font) {
    if (font != null && font.undecodable) {
      undecodableChars += data.length;
      return '';
    }
    final _CMap? cmap = font?.cmap;
    if (cmap != null) {
      final StringBuffer b = StringBuffer();
      final int step = cmap.codeBytes;
      for (int k = 0; k + step <= data.length; k += step) {
        int code = 0;
        for (int j = 0; j < step; j++) {
          code = (code << 8) | data[k + j];
        }
        final String? ch = cmap.map[code];
        if (ch != null) b.write(ch);
      }
      return b.toString();
    }
    // Simple fonts without a map: Latin-1 / WinAnsi approximation.
    final StringBuffer b = StringBuffer();
    for (final int byte in data) {
      if (byte == 9 || byte == 10 || byte >= 32) b.writeCharCode(byte);
    }
    return b.toString();
  }
}
