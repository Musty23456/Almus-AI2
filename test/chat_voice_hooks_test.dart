import 'dart:async';

import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Failing implements ChatService {
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

void main() {
  test('onAssistantReply gets successful replies only', () async {
    final List<ChatMessage> got = <ChatMessage>[];
    final ChatController ok = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
      onAssistantReply: got.add,
    );
    await ok.send('hello');
    expect(got, hasLength(1));
    expect(got.single.sender, MessageSender.assistant);
    expect(got.single.isError, isFalse);
    ok.dispose();

    final List<ChatMessage> errors = <ChatMessage>[];
    final ChatController bad = ChatController(
      service: _Failing(),
      onAssistantReply: errors.add,
    );
    await bad.send('hello');
    expect(errors, isEmpty, reason: 'error messages are never handed to speech');
    bad.dispose();
  });

  test('onConversationChanged fires when the chat is replaced or cleared',
      () async {
    int calls = 0;
    final ChatController c = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
      onConversationChanged: () => calls++,
    );
    c.newConversation();
    expect(calls, 1);
    await c.send('hello');
    c.clear();
    expect(calls, 2);
    c.dispose();
  });

  test('stopping speech by the user returns straight to IDLE', () {
    final ChatController c = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );
    c.setSpeechPlaybackActive(true);
    expect(c.robotState.value, RobotState.talking);
    c.setSpeechPlaybackActive(false, natural: false);
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  test('natural end keeps the Phase 5 smile before IDLE', () async {
    final ChatController c = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
      happyHold: const Duration(milliseconds: 20),
    );
    c.setSpeechPlaybackActive(true);
    c.setSpeechPlaybackActive(false);
    expect(c.robotState.value, RobotState.happy);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(c.robotState.value, RobotState.idle);
    c.dispose();
  });

  test('without a voice feature the simulated talking still runs', () async {
    final ChatController c = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );
    unawaited(c.send('hello'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.robotState.value, RobotState.talking);
    c.dispose();
  });

  test('pausing playback does not leave the avatar talking', () {
    final ChatController c = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );
    c.setSpeechPlaybackActive(true);
    c.setSpeechPlaybackActive(false, natural: false); // paused
    expect(c.robotState.value, RobotState.idle);
    c.setSpeechPlaybackActive(true); // resumed
    expect(c.robotState.value, RobotState.talking);
    c.dispose();
  });
}
