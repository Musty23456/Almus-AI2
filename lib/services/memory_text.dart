import '../models/memory_item.dart';

final RegExp _splitter = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Words that carry no topic (English plus a few common Hausa words).
const Set<String> kStopWords = <String>{
  'a', 'an', 'the', 'and', 'or', 'but', 'if', 'of', 'to', 'in', 'on', 'at',
  'for', 'with', 'about', 'from', 'by', 'is', 'are', 'was', 'were', 'be',
  'been', 'am', 'do', 'does', 'did', 'have', 'has', 'had', 'i', 'me', 'my',
  'mine', 'you', 'your', 'we', 'our', 'he', 'she', 'it', 'its', 'they',
  'them', 'this', 'that', 'these', 'those', 'what', 'which', 'who', 'how',
  'why', 'when', 'where', 'can', 'could', 'would', 'should', 'will', 'shall',
  'may', 'might', 'please', 'tell', 'give', 'show', 'want', 'need', 'just',
  'also', 'so', 'not', 'no', 'yes', 'as', 'than', 'then', 'there', 'here',
  'some', 'any', 'more', 'most', 'very', 'too', 'much', 'many', 'let', 'lets',
  'ok', 'okay', 'hello', 'hi', 'hey', 'thanks', 'thank',
  // Hausa
  'da', 'na', 'ta', 'ne', 'ce', 'ina', 'kai', 'ni', 'shi', 'ita', 'mu', 'ku',
  'su', 'ko', 'kuma', 'amma', 'don', 'domin', 'daga', 'zuwa', 'cikin', 'kan',
  'akan', 'wannan', 'wancan', 'yana', 'tana',
};

/// Lower-cases and removes punctuation so two texts can be compared.
String normalizeMemoryText(String text) {
  return text
      .toLowerCase()
      .split(_splitter)
      .where((String w) => w.isNotEmpty)
      .join(' ');
}

/// Collapses whitespace and trims. Returns an empty string for blank input.
String cleanMemoryText(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Very light stemming so "learning", "learns" and "learned" match "learn".
String stemWord(String word) {
  if (word.length > 5 && word.endsWith('ing')) {
    return word.substring(0, word.length - 3);
  }
  if (word.length > 4 && word.endsWith('ies')) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.length > 4 && word.endsWith('ed')) {
    return word.substring(0, word.length - 2);
  }
  if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// Topic words of [text]: lower-case, stemmed, without stop words.
/// Duplicates are kept so callers can count frequency.
List<String> tokenizeMemory(String text) {
  final List<String> tokens = <String>[];
  for (final String raw in normalizeMemoryText(text).split(' ')) {
    if (raw.length < 2 || kStopWords.contains(raw)) continue;
    tokens.add(stemWord(raw));
  }
  return tokens;
}

/// True when two texts say (almost) the same thing.
bool isDuplicateMemoryText(String a, String b) {
  final String na = normalizeMemoryText(a);
  final String nb = normalizeMemoryText(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;
  final Set<String> ta = tokenizeMemory(a).toSet();
  final Set<String> tb = tokenizeMemory(b).toSet();
  if (ta.length < 3 || tb.length < 3) return false;
  final int shared = ta.intersection(tb).length;
  final int total = ta.union(tb).length;
  return shared / total >= 0.8;
}

/// Finds an existing item that duplicates [text], ignoring [ignoreId].
MemoryItem? findDuplicateMemory(
  String text,
  Iterable<MemoryItem> existing, {
  String? ignoreId,
}) {
  for (final MemoryItem item in existing) {
    if (item.id == ignoreId) continue;
    if (isDuplicateMemoryText(text, item.text)) return item;
  }
  return null;
}
