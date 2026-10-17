import '../models/chat_message.dart';

/// Thrown when a chat engine cannot produce a reply. [message] is safe to show.
class ChatServiceException implements Exception {
  const ChatServiceException(this.message, {this.code = 'error'});

  final String message;

  /// Machine-readable code, e.g. `quota_or_rate_limit`, `network`, `timeout`.
  final String code;

  @override
  String toString() => 'ChatServiceException($code): $message';
}

/// Contract for chat engines.
abstract class ChatService {
  /// Short label shown in the UI, e.g. "DEMO MODE".
  String get engineName;

  /// True when replies are simulated rather than produced by a real AI.
  bool get isDemo;

  /// Produces a reply for [userMessage]. [history] holds earlier messages.
  /// [memoryContext] is the optional block of relevant personal memories
  /// (Phase 4). Engines that do not call a remote AI ignore it.
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  });
}

/// Which provider actually produced a reply (Phase 4), as reported by the backend.
class ReplyProvenance {
  const ReplyProvenance({
    required this.providerId,
    required this.providerName,
    this.model,
    this.fallbackUsed = false,
    this.failedProviders = const <String>[],
    this.omitted = const <String>[],
  });

  final String providerId;
  final String providerName;
  final String? model;

  /// True when the usual provider could not answer and another (allowed) one did.
  final bool fallbackUsed;

  /// Ids of providers that failed before this one answered.
  final List<String> failedProviders;

  /// What was deliberately NOT shared with a fallback provider: `memory`.
  final List<String> omitted;

  /// Short label stored with the message and shown under it, e.g. `GROQ`.
  String get label => providerId.toUpperCase();
}

/// Optional: engines that can say which provider answered the most recent reply.
abstract class ReplyProvenanceSource {
  ReplyProvenance? get lastProvenance;
}
