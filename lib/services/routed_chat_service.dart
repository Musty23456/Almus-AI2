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
import '../local_ai/tools/calculator.dart';
import '../local_ai/tools/unit_conversion.dart';
import '../local_ai/tools/text_tools.dart';
import '../local_ai/tools/statistics.dart';
import '../local_ai/tools/local_history.dart';
import '../local_ai/tools/memory_tools.dart';
import '../local_ai/tools/document_utils.dart';

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
/// otherwise falls back to the scripted demo engine. This class now also consults
/// a LocalAIService for deterministic operations (Phase 5).
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

  /// Phase 5: local deterministic tools layer (optional).
  final LocalAIService? localAI;

  ReplyProvenance? _lastProvenance;

  @override
  ReplyProvenance? get lastProvenance => _lastProvenance;

  Map<String, Object?>? get _routingJson => routing?.value.toRequestJson();

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
    // Attempt deterministic local handling first (Phase 5)
    final local = await _tryLocal(userMessage, history: history);
    if (local != null) return local;

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
    // Attempt deterministic local handling first (Phase 5)
    final local = await _tryLocal(userMessage, history: history);
    if (local != null) return local;

    if (isDemo) {
      _lastProvenance = null;
      return demo.reply(userMessage, history: history);
    }
    return _liveReply(
      buildChatPayload(userMessage, history),
      memoryContext: memoryContext,
    );
  }

  /// Try to run the local AI tools. Returns a non-null string when a local tool
  /// produced a deterministic result; otherwise returns null to indicate the
  /// request should proceed to demo/backend handling.
  Future<String?> _tryLocal(String userMessage, {List<ChatMessage> history = const <ChatMessage>[]}) async {
    if (localAI == null) return null;

    try {
      final ToolResult<dynamic> r = await localAI!.run(userMessage);
      // Format common outputs for chat display.
      final out = r.result;
      final String text = _formatLocalResult(out);

      // Set provenance so UI can label the reply as local
      _lastProvenance = ReplyProvenance(
        providerId: 'local',
        providerName: 'LOCAL',
        model: null,
        fallbackUsed: false,
        failedProviders: const <String>[],
        omitted: const <String>[],
      );

      return '$text\n\n(Locally calculated)';
    } on ToolError catch (e) {
      // If the router determined the intent was ambiguous or the tool refused,
      // do not fail the whole chat; fall back to AI/backend.
      return null;
    } catch (e) {
      // Unexpected local tool failure — prefer to continue with backend rather
      // than surfacing a tool stack trace to the user.
      return null;
    }
  }

  String _formatLocalResult(dynamic out) {
    if (out == null) return '';
    try {
      if (out is CalculatorOutput) return out.formatted;
      if (out is UnitConversionOutput) return '${out.value} ${out.to}';
      if (out is TextToolsOutput) {
        final buf = StringBuffer();
        buf.writeln('Words: ${out.words}');
        buf.writeln('Characters: ${out.characters}');
        buf.writeln('Lines: ${out.lines}');
        if (out.transformed != null) buf.writeln('\nTransformed:\n${out.transformed}');
        return buf.toString().trim();
      }
      if (out is StatisticsOutput) {
        final buf = StringBuffer();
        buf.writeln('Mean: ${out.mean}');
        buf.writeln('Median: ${out.median}');
        buf.writeln('Mode: ${out.mode}');
        buf.writeln('Range: ${out.range}');
        buf.writeln('StdDev: ${out.stddev}');
        return buf.toString().trim();
      }
      if (out is DocumentUtilsOutput) {
        final buf = StringBuffer();
        buf.writeln('File: ${out.metadata['path']}');
        buf.writeln('Size: ${out.metadata['size']} bytes');
        if (out.rows != null) buf.writeln('Rows: ${out.rows}');
        if (out.columns != null) buf.writeln('Columns: ${out.columns}');
        if (out.text != null) buf.writeln('\nPreview:\n${out.text!.substring(0, out.text!.length.clamp(0, 400))}');
        return buf.toString().trim();
      }
      if (out is LocalHistoryOutput) {
        final buf = StringBuffer();
        buf.writeln('Conversations: ${out.conversations.length}');
        for (final c in out.conversations.take(5)) {
          buf.writeln('- ${c['title']} (id=${c['id']})');
        }
        return buf.toString().trim();
      }
      if (out is MemoryToolsOutput) {
        final buf = StringBuffer();
        buf.writeln('Memories found: ${out.memories.length}');
        for (final m in out.memories.take(5)) {
          buf.writeln('- [${m['status']}] ${m['category']}: ${m['text']}');
        }
        return buf.toString().trim();
      }

      // Fallback: stringify
      return out.toString();
    } catch (e) {
      return out.toString();
    }
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
