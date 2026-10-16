import 'package:almus_ai/attachments/attachment_models.dart';
import 'package:almus_ai/attachments/attachment_plan.dart';
import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/chat_message.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chat engine that can read extracted text (like the Gemini route).
class TextReadingService implements AttachmentCapableChatService {
  List<ChatAttachment> received = <ChatAttachment>[];
  String? lastUserText;
  int plainReplies = 0;
  bool failNext = false;

  @override
  String get engineName => 'TEST';
  @override
  bool get isDemo => false;
  @override
  AttachmentSupport get attachmentSupport =>
      const AttachmentSupport(extractedText: true, images: false, providerName: 'TestAI');

  @override
  Future<String> reply(String userMessage, {List<ChatMessage> history = const <ChatMessage>[], String? memoryContext}) async {
    plainReplies++;
    lastUserText = userMessage;
    return 'plain reply';
  }

  @override
  Future<String> replyWithAttachments(
    String userMessage, {
    List<ChatMessage> history = const <ChatMessage>[],
    String? memoryContext,
    required List<ChatAttachment> attachments,
  }) async {
    if (failNext) throw Exception('boom');
    received = attachments;
    lastUserText = userMessage;
    return 'read ${attachments.length} file(s)';
  }
}

ChatAttachment doc(String name, String text, {AttachmentKind kind = AttachmentKind.text, bool truncated = false}) =>
    ChatAttachment(id: name, name: name, sizeBytes: text.length, kind: kind, status: AttachmentStatus.ready, extractedText: text, truncated: truncated);

ChatAttachment image(String name) =>
    ChatAttachment(id: name, name: name, sizeBytes: 2048, kind: AttachmentKind.image, status: AttachmentStatus.ready);

void main() {
  test('planning: text goes to the AI, images never do, unsupported engines read nothing', () {
    const AttachmentSupport reads = AttachmentSupport(extractedText: true, providerName: 'AI');
    final AttachmentPlan p = planAttachments(<ChatAttachment>[doc('a.txt', 'x'), image('p.png')], reads);
    expect(p.analyzable.map((ChatAttachment a) => a.name), <String>['a.txt']);
    expect(p.skipped.single.attachment.name, 'p.png');
    expect(p.skipped.single.reason, contains('images'));

    final AttachmentPlan none = planAttachments(<ChatAttachment>[doc('a.txt', 'x')], AttachmentSupport.none);
    expect(none.analyzable, isEmpty);
    expect(none.skipped.single.reason, contains('DEMO MODE'));

    final AttachmentPlan empty = planAttachments(<ChatAttachment>[doc('e.txt', '')], reads);
    expect(empty.skipped.single.reason, contains('no text'));
  });

  test('footer says what was sent and what was NOT analyzed', () {
    const AttachmentSupport reads = AttachmentSupport(extractedText: true, providerName: 'AI');
    final String footer = attachmentFooter(
      planAttachments(<ChatAttachment>[doc('a.txt', 'x', truncated: true), image('p.png')], reads),
    );
    expect(footer, contains('a.txt'));
    expect(footer, contains('text sent to the AI (shortened)'));
    expect(footer, contains('p.png'));
    expect(footer, contains('NOT analyzed'));
  });

  test('a message with a document: the engine receives its text; typed words stay separate', () async {
    final TextReadingService svc = TextReadingService();
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('Summarise this', attachments: <ChatAttachment>[doc('plan.md', 'Hausa: Ɓarna', kind: AttachmentKind.markdown)]);
    expect(svc.received.single.extractedText, 'Hausa: Ɓarna');
    expect(svc.lastUserText, 'Summarise this');
    final ChatMessage user = chat.messages.first;
    expect(user.text, startsWith('Summarise this'));
    expect(user.text, contains('plan.md'));
    expect(user.attachments.single.analyzed, isTrue);
    expect(chat.messages.last.text, 'read 1 file(s)');
    chat.dispose();
  });

  test('an image is kept in the message but marked not analyzed, and is not sent to the engine', () async {
    final TextReadingService svc = TextReadingService();
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('What is in this picture?', attachments: <ChatAttachment>[image('photo.jpg')]);
    expect(svc.received, isEmpty);
    expect(svc.plainReplies, 1, reason: 'no attachment call when nothing can be read');
    final AttachmentInfo info = chat.messages.first.attachments.single;
    expect(info.analyzed, isFalse);
    expect(info.note, contains('Not analyzed'));
    expect(chat.messages.first.text, contains('NOT analyzed'));
    chat.dispose();
  });

  test('mixed files: only the document is sent; the stored message lists both honestly', () async {
    final TextReadingService svc = TextReadingService();
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('Compare', attachments: <ChatAttachment>[doc('a.csv', 'x,y', kind: AttachmentKind.csv), image('p.png')]);
    expect(svc.received.length, 1);
    expect(chat.messages.first.attachments.map((AttachmentInfo a) => a.analyzed), <bool>[true, false]);
    chat.dispose();
  });

  test('DEMO engine reads nothing and the message says so', () async {
    final ChatController chat = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
      happyHold: const Duration(milliseconds: 10),
    );
    await chat.send('Read this', attachments: <ChatAttachment>[doc('a.txt', 'secret')]);
    expect(chat.attachmentSupport.extractedText, isFalse);
    expect(chat.messages.first.attachments.single.analyzed, isFalse);
    expect(chat.messages.first.text, contains('NOT analyzed'));
    chat.dispose();
  });

  test('file only, no typed words: a default request is sent when the AI can read the file', () async {
    final TextReadingService svc = TextReadingService();
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('', attachments: <ChatAttachment>[doc('a.txt', 'x')]);
    expect(svc.lastUserText, contains('attached file'));
    chat.dispose();
  });

  test('empty send does nothing', () async {
    final TextReadingService svc = TextReadingService();
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('   ');
    expect(chat.messages, isEmpty);
    chat.dispose();
  });

  test('failure while sending a file shows an error bubble and frees the chat', () async {
    final TextReadingService svc = TextReadingService()..failNext = true;
    final ChatController chat = ChatController(service: svc, happyHold: const Duration(milliseconds: 10));
    await chat.send('Read', attachments: <ChatAttachment>[doc('a.txt', 'x')]);
    expect(chat.messages.last.isError, isTrue);
    expect(chat.isBusy, isFalse);
    chat.dispose();
  });
}
