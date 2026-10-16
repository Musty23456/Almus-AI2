import 'dart:convert';
import 'dart:io';

import '../tool.dart';

class DocumentUtilsInput {
  final String path; // local file path accessible to the app
  DocumentUtilsInput(this.path);
}

class DocumentUtilsOutput {
  final Map<String, dynamic> metadata;
  final String? text;
  final int? rows;
  final int? columns;
  DocumentUtilsOutput({required this.metadata, this.text, this.rows, this.columns});
}

class DocumentUtils extends Tool<DocumentUtilsInput, DocumentUtilsOutput> {
  @override
  String get id => 'document_utils';

  @override
  String get description => 'Inspect and extract basic info from supported documents (txt, csv).';

  @override
  String get inputSchema => 'DocumentUtilsInput { path: String }';

  @override
  void validate(DocumentUtilsInput input) {
    if (input.path.isEmpty) throw ToolError('missing_path', 'Path required');
  }

  @override
  Future<ToolResult<DocumentUtilsOutput>> execute(DocumentUtilsInput input) async {
    final f = File(input.path);
    if (!await f.exists()) throw ToolError('not_found', 'File not found');
    final stat = await f.stat();
    final meta = {
      'size': stat.size,
      'modified': stat.modified.toIso8601String(),
      'path': input.path,
    };
    final ext = input.path.split('.').last.toLowerCase();
    if (ext == 'txt' || ext == 'md') {
      final text = await f.readAsString();
      final rows = text.split(RegExp(r"\r?\n")).length;
      return ToolResult(result: DocumentUtilsOutput(metadata: meta, text: text, rows: rows, columns: null));
    }
    if (ext == 'csv') {
      final text = await f.readAsString();
      final lines = text.split(RegExp(r"\r?\n")).where((l) => l.trim().isNotEmpty).toList();
      final rows = lines.length;
      int columns = 0;
      for (final l in lines) {
        final cols = _splitCsvLine(l).length;
        if (cols > columns) columns = cols;
      }
      return ToolResult(result: DocumentUtilsOutput(metadata: meta, text: null, rows: rows, columns: columns));
    }
    throw ToolError('unsupported_format', 'Extension .$ext not supported');
  }

  List<String> _splitCsvLine(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }
      if (c == ',' && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out;
  }
}
