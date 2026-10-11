import '../controllers/settings_controller.dart';
import '../models/chat_message.dart';
import 'backend_client.dart';
import 'chat_service.dart';
import 'demo_chat_service.dart';

/// Conversation limits (the backend enforces the same rules).
const int kMaxHistoryMessages = 20;
const int kMaxMessageChars = 4000;
const int kMaxContextChars = 12000;

/// Builds the message list sent to the backend: recent history plus the new message,
/// skipping error bubbles and staying inside the size limits.
List<Map<String, String>> buildChatPayload(
  String userMessage,
  List<ChatMessage> history,
) {
  final List<Map<String, String>> items = <Map<String, String>>[];
  for (final ChatMessage m in history) {
    if (m.isError) continue;
    final String text =
        m.text.length > kMaxMessageChars ? m.text.substring(0, kMaxMessageChars) : m.text;
    items.add(<String, String>{
      'role': m.sender == MessageSender.user ? 'user' : 'assistant',
      'content': text,
    });
  }
  items.add(<String, String>{'role': 'user', 'content': userMessage.trim()});

  while (items.length > kMaxHistoryMessages) {
    items.removeAt(0);
  }
  int total = items.fold<int>(0, (int sum, Map<String, String> m) => sum + m['content']!.length);
  while (items.length > 1 && total > kMaxContextChars) {
    total -= items.first['content']!.length;
    items.removeAt(0);
  }
  return items;
}

/// Uses the real backend (Gemini) when a backend address is saved in Settings,
/// otherwise falls back to the scripted demo engine.
class RoutedChatService implements ChatService {
  RoutedChatService({
    required this.settings,
    required this.backend,
    ChatService? demo,
  }) : demo = demo ?? DemoChatService();

  final SettingsController settings;
  final BackendClient backend;
  final ChatService demo;

  @override
  bool get isDemo => !settings.value.isConfigured;

  @override
  String get engineName => isDemo ? 'DEMO MODE' : 'LIVE · GEMINI';

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
  }) {
    if (isDemo) {
      return demo.reply(userMessage, history: history);
    }
    return backend.chat(settings.value, buildChatPayload(userMessage, history));
  }
}
