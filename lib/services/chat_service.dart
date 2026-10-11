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
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
  });
}
