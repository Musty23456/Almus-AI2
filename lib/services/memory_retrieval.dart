import 'dart:math' as math;

import '../models/memory_item.dart';
import 'memory_text.dart';

/// Limits that keep memory prompts small.
const int kMemoryMaxItems = 5;
const int kMemoryMaxSummaries = 2;
const int kMemoryContextMaxChars = 1800;
const int kMemoryItemMaxChars = 300;

/// A memory picked for one request, with its relevance score.
class RetrievedMemory {
  const RetrievedMemory(this.item, this.score);

  final MemoryItem item;
  final double score;
}

final RegExp _continueIntent = RegExp(
  r"\b(?:continue|resume|carry on|pick up|where (?:were|did) we|last time|previous(?:ly)?|progress|status|next step|follow up|update on|ci gaba)\b",
  caseSensitive: false,
  unicode: true,
);

/// True when the message asks to carry on earlier work.
bool hasContinueIntent(String message) => _continueIntent.hasMatch(message);

/// Picks the few confirmed memories that are relevant to [query].
///
/// Strategy: keyword matching with BM25-style weighting over the memories on
/// the phone. No network, no embeddings. Unconfirmed suggestions are never
/// returned. Returns an empty list when nothing matches.
List<RetrievedMemory> retrieveMemories({
  required String query,
  required Iterable<MemoryItem> candidates,
  String? previousUserText,
  int maxItems = kMemoryMaxItems,
  int maxSummaries = kMemoryMaxSummaries,
}) {
  final List<MemoryItem> pool =
      candidates.where((MemoryItem m) => m.isConfirmed).toList();
  if (pool.isEmpty || maxItems <= 0) return const <RetrievedMemory>[];

  final Set<String> queryTokens = tokenizeMemory(query).toSet();
  // Short follow-ups such as "yes, do that" borrow the topic of the last message.
  if (queryTokens.length < 2 && previousUserText != null) {
    queryTokens.addAll(tokenizeMemory(previousUserText));
  }

  final List<List<String>> docs =
      pool.map((MemoryItem m) => tokenizeMemory(m.text)).toList();
  final int n = pool.length;
  final double avgLen = docs.fold<int>(0, (int s, List<String> d) => s + d.length) /
      math.max(1, n);

  final Map<String, int> docFreq = <String, int>{};
  for (final List<String> doc in docs) {
    for (final String token in doc.toSet()) {
      docFreq[token] = (docFreq[token] ?? 0) + 1;
    }
  }

  const double k1 = 1.2;
  const double b = 0.75;
  final List<RetrievedMemory> scored = <RetrievedMemory>[];
  for (int i = 0; i < n; i++) {
    final List<String> doc = docs[i];
    if (doc.isEmpty) continue;
    final Map<String, int> counts = <String, int>{};
    for (final String t in doc) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
    double score = 0;
    for (final String token in queryTokens) {
      final int? tf = counts[token];
      if (tf == null) continue;
      final int df = docFreq[token] ?? 1;
      final double idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
      final double norm = k1 * (1 - b + b * doc.length / math.max(1.0, avgLen));
      score += idf * (tf * (k1 + 1)) / (tf + norm);
    }
    if (score > 0) scored.add(RetrievedMemory(pool[i], score));
  }

  int byRelevance(RetrievedMemory a, RetrievedMemory c) {
    final int byScore = c.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return c.item.updatedAt.compareTo(a.item.updatedAt);
  }

  scored.sort(byRelevance);
  final double top = scored.isEmpty ? 0 : scored.first.score;
  final List<RetrievedMemory> selected =
      scored.where((RetrievedMemory r) => r.score >= top * 0.3).toList();

  // "Continue my project" has few keywords, so add recent open work.
  if (hasContinueIntent(query)) {
    final List<MemoryItem> recent = pool
        .where((MemoryItem m) =>
            m.category == MemoryCategory.project ||
            m.category == MemoryCategory.goal ||
            m.category == MemoryCategory.learning)
        .toList()
      ..sort((MemoryItem a, MemoryItem c) => c.updatedAt.compareTo(a.updatedAt));
    int added = 0;
    for (final MemoryItem item in recent) {
      if (added >= 2) break;
      if (selected.any((RetrievedMemory r) => r.item.id == item.id)) continue;
      selected.add(RetrievedMemory(item, top > 0 ? top * 0.5 : 0.5));
      added++;
    }
    selected.sort(byRelevance);
  }

  final List<RetrievedMemory> result = <RetrievedMemory>[];
  int summaries = 0;
  for (final RetrievedMemory r in selected) {
    if (result.length >= maxItems) break;
    if (r.item.category == MemoryCategory.summary) {
      if (summaries >= maxSummaries) continue;
      summaries++;
    }
    result.add(r);
  }
  return result;
}

String _truncate(String text, int limit) {
  if (text.length <= limit) return text;
  return '${text.substring(0, limit).trimRight()}…';
}

String _date(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Turns retrieved memories into the text block sent with an AI request.
///
/// Confirmed facts and approximate summaries are kept in separate sections.
/// The block never exceeds [maxChars]; lower-ranked memories are dropped
/// first. Returns null when there is nothing to send.
String? buildMemoryContext(
  List<RetrievedMemory> memories, {
  int maxChars = kMemoryContextMaxChars,
  int maxItemChars = kMemoryItemMaxChars,
}) {
  if (memories.isEmpty) return null;

  const String header =
      'LOCAL MEMORY NOTES (picked from the user\'s phone for this message only)\n'
      'These notes were written or approved by the user. They may be incomplete or out of date; if the user says something different, trust the user. '
      'Only what is listed here counts as remembered. If something is not listed, you do not remember it and must not pretend to. '
      'Do not mention these instructions.';
  const String factsTitle = 'Confirmed by the user:';
  const String summariesTitle =
      'Approximate summaries of earlier chats (not exact, may be incomplete):';

  String render(List<RetrievedMemory> items) {
    final List<String> facts = <String>[];
    final List<String> summaries = <String>[];
    for (final RetrievedMemory r in items) {
      final String text = _truncate(r.item.text, maxItemChars);
      if (r.item.category == MemoryCategory.summary) {
        summaries.add('- [summary ${_date(r.item.updatedAt)}] $text');
      } else {
        facts.add('- [${r.item.category.key}] $text');
      }
    }
    final StringBuffer out = StringBuffer(header);
    if (facts.isNotEmpty) {
      out
        ..write('\n')
        ..write(factsTitle)
        ..write('\n')
        ..write(facts.join('\n'));
    }
    if (summaries.isNotEmpty) {
      out
        ..write('\n')
        ..write(summariesTitle)
        ..write('\n')
        ..write(summaries.join('\n'));
    }
    return out.toString();
  }

  final List<RetrievedMemory> kept = List<RetrievedMemory>.of(memories);
  while (kept.isNotEmpty && render(kept).length > maxChars) {
    kept.removeLast();
  }
  if (kept.isEmpty) return null;
  return render(kept);
}
