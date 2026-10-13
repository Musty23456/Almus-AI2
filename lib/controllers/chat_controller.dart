import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/conversation_repository.dart';
import '../data/memory_conversation_repository.dart';
import '../data/storage_exception.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/memory_item.dart';
import '../models/robot_state.dart';
import '../services/memory_retrieval.dart';
import '../services/chat_service.dart';
import '../services/demo_chat_service.dart';
import '../utils/ids.dart';
import '../voice/voice_controller.dart';
import 'memory_controller.dart';

/// Holds the open conversation, the robot's state, and saves messages through
/// a [ConversationRepository]. A storage problem never blocks chatting: the
/// message stays on screen and [storageNotice] explains what happened.
class ChatController extends ChangeNotifier implements VoiceAvatarHooks {
  ChatController({
    ChatService? service,
    Listenable? engineChanges,
    ConversationRepository? repository,
    this.persistent = true,
    this.memory,
    this.onAssistantReply,
    this.onConversationChanged,
    this.happyHold = const Duration(milliseconds: 1500),
  })  : service = service ?? DemoChatService(),
        repository = repository ?? MemoryConversationRepository(),
        _engineChanges = engineChanges {
    _engineChanges?.addListener(notifyListeners);
  }

  final ChatService service;
  final ConversationRepository repository;

  /// Personal memory (Phase 4). Null disables every memory feature.
  final MemoryController? memory;

  /// Phase 6: called with every successful assistant reply (never with error
  /// messages) so the voice feature can read it aloud.
  final void Function(ChatMessage message)? onAssistantReply;

  /// Phase 6: called when the open conversation is replaced, deleted or
  /// cleared, so listening and speech stop instead of carrying over.
  final VoidCallback? onConversationChanged;

  /// False when the database could not be opened (history will not survive a restart).
  final bool persistent;

  /// How long the HAPPY avatar state is shown after a reply or a celebration.
  final Duration happyHold;

  /// Notifies the UI when the engine can change (e.g. backend saved in Settings).
  final Listenable? _engineChanges;

  /// Current robot avatar state (shared by Home and Chat).
  final ValueNotifier<RobotState> robotState =
      ValueNotifier<RobotState>(RobotState.idle);

  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _storedConversations = <String>{};
  bool _busy = false;
  bool _voiceInput = false;
  bool _speechPlayback = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _idleTimer;
  Future<void> _storageQueue = Future<void>.value();

  String? _conversationId;
  String? _conversationTitle;
  String? _storageError;
  bool _chatMemoryOff = false;
  List<MemoryItem> _lastMemoryUsed = const <MemoryItem>[];

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  @override
  bool get isBusy => _busy;
  bool get isDemo => service.isDemo;
  String get engineName => service.engineName;

  /// Id of the open conversation (null for a new chat that has no messages yet).
  String? get conversationId => _conversationId;
  String? get conversationTitle => _conversationTitle;

  /// True when the user switched memory off for the open chat. Nothing is
  /// retrieved or suggested for it.
  bool get chatMemoryOff => _chatMemoryOff;

  /// Memories that were included in the most recent AI request (empty when
  /// none were sent). Shown to the user for transparency.
  List<MemoryItem> get lastMemoryUsed => _lastMemoryUsed;

  /// A user-safe message when history cannot be saved or loaded, else null.
  String? get storageNotice {
    if (_storageError != null) return _storageError;
    if (!persistent) {
      return 'Chat history cannot be saved on this device right now. Your messages are kept only until you close the app.';
    }
    return null;
  }

  /// Completes when every queued database write has finished.
  Future<void> flushStorage() => _storageQueue;

  /// Lets the UI simulate any robot state (Phase 1 preview controls).
  void setRobotState(RobotState state) {
    if (_disposed) return;
    _idleTimer?.cancel();
    robotState.value = state;
  }

  /// Called while the user types in the chat input.
  void userTyping(bool typing) {
    if (_disposed || _busy || _voiceInput) return;
    if (typing && robotState.value == RobotState.idle) {
      robotState.value = RobotState.listening;
    } else if (!typing && robotState.value == RobotState.listening) {
      robotState.value = RobotState.idle;
    }
  }

  /// Voice input (microphone) started or stopped. Drives LISTENING.
  ///
  /// Phase 6: called by the VoiceController while the microphone is open.
  /// While an AI request is pending, THINKING keeps priority.
  @override
  void setVoiceInputActive(bool active) {
    if (_disposed) return;
    _voiceInput = active;
    if (_busy) return;
    if (active) {
      _idleTimer?.cancel();
      robotState.value = RobotState.listening;
    } else if (robotState.value == RobotState.listening) {
      robotState.value = RobotState.idle;
    }
  }

  /// Speech playback (text-to-speech) started or stopped. Drives TALKING.
  ///
  /// Without audio, after a reply the avatar talks for a time based on the
  /// reply length. With text-to-speech (Phase 6) the VoiceController calls
  /// this, so TALKING lasts as long as the audio: there is no phoneme data, so
  /// the mouth animation is a generic talking loop, not true lip-sync.
  ///
  /// When playback ends on its own ([natural] true) a brief HAPPY smile
  /// precedes IDLE (the Phase 5 behaviour). When the user stopped it or it
  /// failed ([natural] false) the avatar goes straight to IDLE.
  @override
  void setSpeechPlaybackActive(bool active, {bool natural = true}) {
    if (_disposed) return;
    _speechPlayback = active;
    if (active) {
      _idleTimer?.cancel();
      if (!_busy && !_voiceInput) robotState.value = RobotState.talking;
    } else if (!_busy && robotState.value == RobotState.talking) {
      if (natural) {
        robotState.value = RobotState.happy;
        _scheduleIdle(happyHold);
      } else {
        _idleTimer?.cancel();
        robotState.value = RobotState.idle;
      }
    }
  }

  /// A short HAPPY moment (for example when the user taps the avatar).
  void celebrate() {
    if (_disposed || _busy || _speechPlayback || _voiceInput) return;
    robotState.value = RobotState.happy;
    _scheduleIdle(happyHold);
  }

  /// Shows ERROR for a few seconds, for failures outside chat (a future
  /// microphone or speech failure). Chat failures already do this.
  @override
  void reportFailure() {
    if (_disposed) return;
    _voiceInput = false;
    _speechPlayback = false;
    robotState.value = RobotState.error;
    _scheduleIdle(const Duration(seconds: 3));
  }

  Future<void> send(String raw) async {
    final String text = raw.trim();
    if (_disposed || text.isEmpty || _busy) return;

    _idleTimer?.cancel();
    final int generation = _generation;
    final List<ChatMessage> history = List<ChatMessage>.of(_messages);
    final ChatMessage userMessage = _newMessage(text, MessageSender.user);
    _messages.add(userMessage);
    _busy = true;
    robotState.value = RobotState.thinking;
    notifyListeners();
    _enqueueSave(userMessage);
    _suggestMemories(text, userMessage.conversationId);

    try {
      final MemoryContext context = await _memoryContextFor(text, history);
      if (_disposed || generation != _generation) return;
      _lastMemoryUsed =
          context.used.map((RetrievedMemory r) => r.item).toList();
      final String reply = await service.reply(
        text,
        history: history,
        memoryContext: context.text,
      );
      if (_disposed || generation != _generation) return;
      final ChatMessage assistantMessage = _newMessage(
        reply,
        MessageSender.assistant,
        engineLabel: service.isDemo ? 'DEMO' : 'GEMINI',
      );
      _messages.add(assistantMessage);
      _busy = false;
      robotState.value = RobotState.talking;
      notifyListeners();
      _enqueueSave(assistantMessage);
      // Phase 6: let the voice feature read the reply aloud (if enabled).
      onAssistantReply?.call(assistantMessage);
      if (!_speechPlayback) {
        // No audio engine: simulate speaking time, then a short smile.
        _scheduleIdle(
          Duration(
            milliseconds: math.min(5000, math.max(1500, reply.length * 28)),
          ),
          happyFirst: true,
        );
      }
    } on ChatServiceException catch (e) {
      _fail(generation, e.message);
    } on Exception {
      _fail(generation, 'Something unexpected went wrong. Please try again.');
    }
  }

  /// Picks relevant memories for a live request. Nothing is retrieved in
  /// DEMO MODE (nothing is sent anywhere), when memory is off, or when
  /// memory fails: chatting always keeps working.
  Future<MemoryContext> _memoryContextFor(
    String text,
    List<ChatMessage> history,
  ) async {
    final MemoryController? m = memory;
    if (m == null || service.isDemo) return MemoryContext.none;
    String? previousUserText;
    for (int i = history.length - 1; i >= 0; i--) {
      if (history[i].sender == MessageSender.user && !history[i].isError) {
        previousUserText = history[i].text;
        break;
      }
    }
    try {
      return await m.contextFor(
        text,
        previousUserText: previousUserText,
        chatMemoryOff: _chatMemoryOff,
      );
    } on Exception {
      return MemoryContext.none;
    }
  }

  /// Proposes memories from the user's message (never saves them).
  void _suggestMemories(String text, String conversationId) {
    final MemoryController? m = memory;
    if (m == null || _chatMemoryOff) return;
    unawaited(m.suggestFrom(text, conversationId: conversationId));
  }

  /// Turns memory off (or on again) for the open chat only.
  Future<void> setChatMemoryOff(bool off) async {
    if (_disposed) return;
    _chatMemoryOff = off;
    if (off) _lastMemoryUsed = const <MemoryItem>[];
    notifyListeners();
    final String? id = _conversationId;
    if (id != null) {
      await memory?.setConversationOff(id, off);
    }
  }

  void _fail(int generation, String message) {
    if (_disposed || generation != _generation) return;
    final ChatMessage errorMessage =
        _newMessage(message, MessageSender.assistant, isError: true);
    _messages.add(errorMessage);
    _busy = false;
    robotState.value = RobotState.error;
    notifyListeners();
    _enqueueSave(errorMessage);
    _scheduleIdle(const Duration(seconds: 3));
  }

  // ---------------------------------------------------------------- storage

  void _enqueueSave(ChatMessage message) {
    _storageQueue = _storageQueue.then((_) => _save(message));
  }

  Future<void> _save(ChatMessage message) async {
    final String? previousError = _storageError;
    final String? previousTitle = _conversationTitle;
    try {
      if (!_storedConversations.contains(message.conversationId)) {
        final String title = titleFromMessage(message.text);
        await repository.createConversation(
          id: message.conversationId,
          title: title,
          createdAt: message.timestamp,
        );
        _storedConversations.add(message.conversationId);
        if (message.conversationId == _conversationId) {
          _conversationTitle = title;
        }
      }
      await repository.addMessage(message);
      _storageError = null;
    } on StorageException catch (e) {
      _storageError =
          'Could not save this chat to your phone (${e.message}) Messages still work, but they may be lost when you close the app.';
    }
    final bool changed =
        previousError != _storageError || previousTitle != _conversationTitle;
    if (!_disposed && changed) notifyListeners();
  }

  /// Opens the most recent saved conversation (called once at app start).
  Future<void> restoreLatest() async {
    try {
      final List<Conversation> latest =
          await repository.listConversations(limit: 1);
      if (latest.isEmpty) return;
      if (_conversationId != null || _messages.isNotEmpty || _busy) return;
      await openConversation(latest.first.id);
    } on StorageException catch (e) {
      _storageError = 'Could not load your saved chats (${e.message})';
      if (!_disposed) notifyListeners();
    }
  }

  /// Loads a saved conversation into the chat screen.
  Future<bool> openConversation(String id) async {
    await _storageQueue;
    try {
      final Conversation? conversation = await repository.getConversation(id);
      if (conversation == null) {
        _storageError = 'That conversation no longer exists.';
        if (!_disposed) notifyListeners();
        return false;
      }
      final List<ChatMessage> stored = await repository.loadMessages(id);
      final bool memoryOff = await memory?.isConversationOff(id) ?? false;
      if (_disposed) return false;
      _resetState();
      _chatMemoryOff = memoryOff;
      _messages.addAll(stored);
      _conversationId = id;
      _conversationTitle = conversation.title;
      _storedConversations.add(id);
      _storageError = null;
      notifyListeners();
      return true;
    } on StorageException catch (e) {
      _storageError = 'Could not open that chat (${e.message})';
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  /// Starts an empty chat. The old conversation stays saved.
  void newConversation() {
    if (_disposed) return;
    _resetState();
    notifyListeners();
  }

  /// Deletes the open conversation from this device and starts a new chat.
  void clear() {
    if (_disposed) return;
    final String? id = _conversationId;
    _resetState();
    if (id != null) {
      _storedConversations.remove(id);
      _storageQueue = _storageQueue.then((_) => _runStorage(
            () => repository.deleteConversation(id),
            'delete that chat',
          ));
      unawaited(memory?.setConversationOff(id, false));
    }
    notifyListeners();
  }

  Future<bool> renameConversation(String id, String title) async {
    await _storageQueue;
    final bool ok = await _runStorage(
      () => repository.renameConversation(id, title),
      'rename that chat',
    );
    if (ok && id == _conversationId) {
      _conversationTitle = cleanTitle(title) ?? _conversationTitle;
      if (!_disposed) notifyListeners();
    }
    return ok;
  }

  Future<bool> deleteConversation(String id) async {
    await _storageQueue;
    final bool ok = await _runStorage(
      () => repository.deleteConversation(id),
      'delete that chat',
    );
    if (ok) {
      _storedConversations.remove(id);
      unawaited(memory?.setConversationOff(id, false));
      if (id == _conversationId) {
        _resetState();
        if (!_disposed) notifyListeners();
      }
    }
    return ok;
  }

  /// Deletes every saved conversation and starts a new chat.
  Future<bool> clearAllHistory() async {
    await _storageQueue;
    final bool ok = await _runStorage(repository.clearAll, 'clear your history');
    if (ok) {
      _storedConversations.clear();
      unawaited(memory?.forgetConversationFlags());
      _resetState();
      if (!_disposed) notifyListeners();
    }
    return ok;
  }

  Future<bool> _runStorage(Future<void> Function() action, String what) async {
    try {
      await action();
      return true;
    } on StorageException catch (e) {
      _storageError = 'Could not $what (${e.message})';
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  void _resetState() {
    onConversationChanged?.call();
    _idleTimer?.cancel();
    _generation++;
    _messages.clear();
    _busy = false;
    _conversationId = null;
    _conversationTitle = null;
    _chatMemoryOff = false;
    _lastMemoryUsed = const <MemoryItem>[];
    _voiceInput = false;
    _speechPlayback = false;
    robotState.value = RobotState.idle;
  }

  /// After [delay] the avatar returns to IDLE (or smiles first when
  /// [happyFirst] is true). It never interrupts a request, voice input or
  /// speech playback that started in the meantime.
  void _scheduleIdle(Duration delay, {bool happyFirst = false}) {
    _idleTimer?.cancel();
    _idleTimer = Timer(delay, () {
      if (_disposed || _busy || _speechPlayback || _voiceInput) return;
      if (happyFirst) {
        robotState.value = RobotState.happy;
        _scheduleIdle(happyHold);
      } else {
        robotState.value = RobotState.idle;
      }
    });
  }

  ChatMessage _newMessage(
    String text,
    MessageSender sender, {
    bool isError = false,
    String engineLabel = 'DEMO',
  }) {
    if (_conversationId == null) {
      final String created = newId('c');
      _conversationId = created;
      // The user switched memory off before the first message: remember it.
      if (_chatMemoryOff) {
        unawaited(memory?.setConversationOff(created, true));
      }
    }
    return ChatMessage(
      id: newId('m'),
      conversationId: _conversationId!,
      text: text,
      sender: sender,
      timestamp: DateTime.now(),
      isError: isError,
      engineLabel: engineLabel,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _engineChanges?.removeListener(notifyListeners);
    _idleTimer?.cancel();
    robotState.dispose();
    super.dispose();
  }
}
