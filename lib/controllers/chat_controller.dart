import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/robot_state.dart';
import '../services/chat_service.dart';
import '../services/demo_chat_service.dart';

/// Holds the in-memory conversation and the robot's state.
/// Nothing is persisted: messages disappear when the app closes.
class ChatController extends ChangeNotifier {
  ChatController({ChatService? service})
      : service = service ?? DemoChatService();

  final ChatService service;

  /// Current robot avatar state (shared by Home and Chat).
  final ValueNotifier<RobotState> robotState =
      ValueNotifier<RobotState>(RobotState.idle);

  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  int _counter = 0;
  Timer? _idleTimer;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get isBusy => _busy;
  bool get isDemo => service.isDemo;
  String get engineName => service.engineName;

  /// Lets the UI simulate any robot state (Phase 1 preview controls).
  void setRobotState(RobotState state) {
    if (_disposed) return;
    _idleTimer?.cancel();
    robotState.value = state;
  }

  /// Called while the user types in the chat input.
  void userTyping(bool typing) {
    if (_disposed || _busy) return;
    if (typing && robotState.value == RobotState.idle) {
      robotState.value = RobotState.listening;
    } else if (!typing && robotState.value == RobotState.listening) {
      robotState.value = RobotState.idle;
    }
  }

  Future<void> send(String raw) async {
    final String text = raw.trim();
    if (_disposed || text.isEmpty || _busy) return;

    _idleTimer?.cancel();
    final int generation = _generation;
    _messages.add(_newMessage(text, MessageSender.user));
    _busy = true;
    robotState.value = RobotState.thinking;
    notifyListeners();

    try {
      final String reply = await service.reply(text);
      if (_disposed || generation != _generation) return;
      _messages.add(_newMessage(reply, MessageSender.assistant));
      _busy = false;
      robotState.value = RobotState.talking;
      notifyListeners();
      _scheduleIdle(
        Duration(
          milliseconds: math.min(5000, math.max(1500, reply.length * 28)),
        ),
      );
    } on ChatServiceException catch (e) {
      _fail(generation, e.message);
    } on Exception {
      _fail(generation, 'Something unexpected went wrong. Please try again.');
    }
  }

  void _fail(int generation, String message) {
    if (_disposed || generation != _generation) return;
    _messages.add(_newMessage(message, MessageSender.assistant, isError: true));
    _busy = false;
    robotState.value = RobotState.error;
    notifyListeners();
    _scheduleIdle(const Duration(seconds: 3));
  }

  /// Removes all messages and resets the robot to idle.
  void clear() {
    if (_disposed) return;
    _idleTimer?.cancel();
    _generation++;
    _messages.clear();
    _busy = false;
    robotState.value = RobotState.idle;
    notifyListeners();
  }

  void _scheduleIdle(Duration delay) {
    _idleTimer?.cancel();
    _idleTimer = Timer(delay, () {
      if (!_disposed && !_busy) {
        robotState.value = RobotState.idle;
      }
    });
  }

  ChatMessage _newMessage(
    String text,
    MessageSender sender, {
    bool isError = false,
  }) {
    _counter++;
    return ChatMessage(
      id: '${DateTime.now().microsecondsSinceEpoch}-$_counter',
      text: text,
      sender: sender,
      timestamp: DateTime.now(),
      isError: isError,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    robotState.dispose();
    super.dispose();
  }
}
