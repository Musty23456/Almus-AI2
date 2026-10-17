import 'dart:async';

import '../ai/routing_preferences.dart';
import '../attachments/attachment_models.dart';
import '../attachments/attachment_plan.dart';
import '../controllers/settings_controller.dart';
import '../models/chat_message.dart';
import 'backend_client.dart';
import 'chat_service.dart';
import 'demo_chat_service.dart';

// Local AI integration
import '../local_ai/local_ai_service.dart';
import '../local_ai/tool.dart';


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
class RoutedChatService implements AttachmentCapableChatService, ReplyProvenanceSource {
  RoutedChatService({
    required this.settings,
    required this.backend,
    ChatService? demo,
    this.routing,
    this.localAI,
  }) : demo = demo ?? DemoChatService();

  final SettingsController settings;
  final BackendClient backend;
  final ChatService demo;

  /// Phase 4: the user's provider choices (null = backend defaults, nothing extra is sent).
  final RoutingPreferencesController? routing;

  /// Phase 5: deterministic local tools. When present, they are preferred before
  /// falling back to the configured backend or demo engine.
  final LocalAIService? localAI;

  ReplyProvenance? _lastProvenance;

  @override
  ReplyProvenance? get lastProvenance => _lastProvenance;

  Map<String, Object?>? get _routingJson => routing?.value.toRequestJson();

  Future<String?> _tryLocalReply(String userMessage) async {
    if (localAI == null) return null;
    try {
      final ToolResult<dynamic> result = await localAI!.run(userMessage);
      final Object? value = result.result;
      _lastProvenance = null;
      if (value == null) return null;
      return value.toString();
    } on ToolError {
      return null;
    }
  }

  @override
  bool get isDemo => !settings.value.isConfigured;

  @override
  String get engineName => isDemo ? 'DEMO MODE' : 'LIVE · GEMINI';

  @override
  AttachmentSupport get attachmentSupport => isDemo
      ? AttachmentSupport.none
      : const AttachmentSupport(
          extractedText: true,
          images: false,
          providerName: 'your AI provider (through your backend)',
        );

  @override
  Future<String> replyWithAttachments(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
    required List<ChatAttachment> attachments,
  }) async {
    final String? localReply = await _tryLocalReply(userMessage);
    if (localReply != null) {
      return localReply;
    }
    if (isDemo) {
      _lastProvenance = null;
      return demo.reply(userMessage, history: history);
    }
    return _liveReply(
      buildChatPayload(userMessage, history),
      memoryContext: memoryContext,
      attachments: <Map<String, Object?>>[
        for (final ChatAttachment a in attachments)
          if (a.kind?.apiKind != null && a.hasText)
            <String, Object?>{
              'name': a.name,
              'kind': a.kind!.apiKind,
              'text': a.extractedText,
              'truncated': a.truncated,
            },
      ],
    );
  }

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async {
    final String? localReply = await _tryLocalReply(userMessage);
    if (localReply != null) {
      return localReply;
    }
    if (isDemo) {
      _lastProvenance = null;
      return demo.reply(userMessage, history: history);
    }
    return _liveReply(
      buildChatPayload(userMessage, history),
      memoryContext: memoryContext,
    );
  }

  Future<String> _liveReply(
    List<Map<String, String>> payload, {
    String? memoryContext,
    List<Map<String, Object?>>? attachments,
  }) async {
    _lastProvenance = null;
    final ChatReply reply = await backend.chatWithInfo(
      settings.value,
      payload,
      memoryContext: memoryContext,
      attachments: attachments,
      routing: _routingJson,
    );
    _lastProvenance = reply.provenance;
    return reply.text;
  }
}
