import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chat engine that fails with whatever object it is given.
class _ThrowingService implements ChatService {
  _ThrowingService(this.error);

  final Object error;

  @override
  String get engineName => 'TEST';

  @override
  bool get isDemo => true;

  @override
  Future<String> reply(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
  }) async {
    throw error;
  }
}

void main() {
  test('a Dart Error from the chat engine does not leave the chat busy',
      () async {
    final ChatController chat =
        ChatController(service: _ThrowingService(StateError('boom')));
    addTearDown(chat.dispose);

    await chat.send('hello');

    expect(chat.isBusy, isFalse);
    expect(chat.robotState.value, RobotState.error);
    expect(chat.messages.last.isError, isTrue);
    // The raw error text must never be shown to the user.
    expect(chat.messages.last.text, isNot(contains('boom')));

    // The chat still accepts a new message afterwards.
    await chat.send('again');
    expect(chat.messages.where((ChatMessage m) => !m.isError).length, 2);
  });

  test('a ChatServiceException shows its safe message', () async {
    final ChatController chat = ChatController(
      service: _ThrowingService(
        const ChatServiceException('Backend unreachable.', code: 'network'),
      ),
    );
    addTearDown(chat.dispose);

    await chat.send('hello');

    expect(chat.isBusy, isFalse);
    expect(chat.messages.last.text, 'Backend unreachable.');
  });
}
