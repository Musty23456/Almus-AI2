/// Thrown when a chat engine cannot produce a reply.
class ChatServiceException implements Exception {
  const ChatServiceException(this.message);

  final String message;

  @override
  String toString() => 'ChatServiceException: $message';
}

/// Contract for chat engines.
///
/// Phase 1 ships [DemoChatService] only. Phase 2 can add a Gemini-backed
/// implementation without touching the UI.
abstract class ChatService {
  /// Short label shown in the UI, e.g. "DEMO MODE".
  String get engineName;

  /// True when replies are simulated rather than produced by a real AI.
  bool get isDemo;

  /// Produces a reply for [userMessage].
  Future<String> reply(String userMessage);
}
