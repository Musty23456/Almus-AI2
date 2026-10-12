import 'dart:async';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chat engine whose reply is released by the test.
class _ManualService implements ChatService {
  final Completer<String> completer = Completer<String>();

  @override
  String get engineName => 'TEST';
  @override
  bool get isDemo => true;

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) =>
      completer.future;
}

class _FailingService implements ChatService {
  @override
  String get engineName => 'TEST';
  @override
  bool get isDemo => true;

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async =>
      throw const ChatServiceException('boom');
}

ChatController _demo() => ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );

void main() {
  testWidgets('waiting for input is IDLE', (tester) async {
    final ChatController c = _demo();
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('voice input drives LISTENING and back to IDLE', (tester) async {
    final ChatController c = _demo();
    c.setVoiceInputActive(true);
    expect(c.robotState.value, RobotState.listening);
    // Typing callbacks must not cancel voice listening.
    c.userTyping(false);
    expect(c.robotState.value, RobotState.listening);
    c.setVoiceInputActive(false);
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('pending AI request is THINKING and keeps priority over voice',
      (tester) async {
    final _ManualService service = _ManualService();
    final ChatController c = ChatController(service: service);
    unawaited(c.send('hi'));
    await tester.pump();
    expect(c.robotState.value, RobotState.thinking);

    c.setVoiceInputActive(true);
    expect(c.robotState.value, RobotState.thinking);
    c.setVoiceInputActive(false);

    service.completer.complete('hello there');
    await tester.pump(const Duration(milliseconds: 10));
    expect(c.robotState.value, RobotState.talking);
    await tester.pump(const Duration(seconds: 8));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('speech playback holds TALKING until it ends, then HAPPY, IDLE',
      (tester) async {
    final ChatController c = _demo();
    c.setSpeechPlaybackActive(true);
    expect(c.robotState.value, RobotState.talking);

    await tester.pump(const Duration(seconds: 30));
    expect(c.robotState.value, RobotState.talking);

    c.setSpeechPlaybackActive(false);
    expect(c.robotState.value, RobotState.happy);
    await tester.pump(const Duration(seconds: 2));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('a reply while speech is playing does not drop to IDLE early',
      (tester) async {
    final ChatController c = _demo();
    unawaited(c.send('hello'));
    await tester.pump(const Duration(milliseconds: 10));
    c.setSpeechPlaybackActive(true);
    await tester.pump(const Duration(seconds: 20));
    expect(c.robotState.value, RobotState.talking);
    c.setSpeechPlaybackActive(false);
    await tester.pump(const Duration(seconds: 3));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('failure shows ERROR then returns to IDLE', (tester) async {
    final ChatController c = ChatController(service: _FailingService());
    unawaited(c.send('hi'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(c.robotState.value, RobotState.error);
    await tester.pump(const Duration(seconds: 4));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('reportFailure shows ERROR for non-chat failures',
      (tester) async {
    final ChatController c = _demo();
    c.setVoiceInputActive(true);
    c.reportFailure();
    expect(c.robotState.value, RobotState.error);
    await tester.pump(const Duration(seconds: 4));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('celebrate gives a short HAPPY moment', (tester) async {
    final ChatController c = _demo();
    c.celebrate();
    expect(c.robotState.value, RobotState.happy);
    await tester.pump(const Duration(seconds: 2));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  testWidgets('new conversation resets voice and speech flags',
      (tester) async {
    final ChatController c = _demo();
    c.setSpeechPlaybackActive(true);
    c.newConversation();
    expect(c.robotState.value, RobotState.idle);
    c.userTyping(true);
    expect(c.robotState.value, RobotState.listening);
    c.userTyping(false);
    c.dispose();
  });
}
