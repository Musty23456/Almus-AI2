import '../tool.dart';

class TextToolsInput {
  final String text;
  final String? transform; // 'lower', 'upper', 'trim'
  TextToolsInput({required this.text, this.transform});
}

class TextToolsOutput {
  final int words;
  final int characters;
  final int lines;
  final String? transformed;
  TextToolsOutput({required this.words, required this.characters, required this.lines, this.transformed});
}

class TextTools extends Tool<TextToolsInput, TextToolsOutput> {
  @override
  String get id => 'text_tools';

  @override
  String get description => 'Counts and simple text transformations.';

  @override
  String get inputSchema => 'TextToolsInput { text: String, transform?: lower|upper|trim }';

  @override
  void validate(TextToolsInput input) {
    if (input.text == null) throw ToolError('missing_text', 'text is required');
  }

  @override
  Future<ToolResult<TextToolsOutput>> execute(TextToolsInput input) async {
    final text = input.text;
    final words = text.trim().isEmpty ? 0 : RegExp(r"\\w+").allMatches(text).length;
    final characters = text.length;
    final lines = text.split(RegExp(r"\r?\n")).length;
    String? transformed;
    if (input.transform != null) {
      switch (input.transform) {
        case 'lower':
          transformed = text.toLowerCase();
          break;
        case 'upper':
          transformed = text.toUpperCase();
          break;
        case 'trim':
          transformed = text.trim();
          break;
        default:
          throw ToolError('unknown_transform', 'Unknown transform ${input.transform}');
      }
    }
    return ToolResult(result: TextToolsOutput(words: words, characters: characters, lines: lines, transformed: transformed));
  }
}
