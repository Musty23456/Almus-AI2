import 'chat_service.dart';

/// Phase 1 engine: scripted replies for testing the interface.
/// It is NOT connected to Gemini or any other AI service.
class DemoChatService implements ChatService {
  DemoChatService({this.thinkingDelay = const Duration(milliseconds: 1100)});

  /// Simulated "thinking" time before a reply is returned.
  final Duration thinkingDelay;

  int _cursor = 0;

  static const List<String> _fallbacks = <String>[
    'This is a scripted DEMO reply. Real answers will arrive when the Gemini integration is added in Phase 2.',
    'Thanks for your message! I am running in DEMO MODE, so I can only show how a conversation will look and feel.',
    'Interesting! In a later phase I will be able to give you a real answer. For now this reply is simulated.',
  ];

  @override
  String get engineName => 'DEMO MODE';

  @override
  bool get isDemo => true;

  @override
  Future<String> reply(String userMessage) async {
    await Future<void>.delayed(thinkingDelay);

    final String text = userMessage.trim().toLowerCase();
    final Set<String> words = text
        .split(RegExp(r'[^a-z]+'))
        .where((String w) => w.isNotEmpty)
        .toSet();

    if (text == '/error') {
      throw const ChatServiceException(
        'Simulated failure: you typed /error to test the error state. Nothing is actually broken.',
      );
    }
    if (words.any(<String>{'hello', 'hi', 'hey', 'salam', 'sannu'}.contains)) {
      return 'Hello! I am Almus, currently running in DEMO MODE. My replies are scripted so you can test the interface.';
    }
    if (text.contains('what can you do') || words.contains('help')) {
      return 'In this demo I can only show how chat looks. Later phases are planned to add real AI answers, voice and long-term memory.';
    }
    if (words.contains('gemini')) {
      return 'Gemini is not connected yet. The real integration is planned for Phase 2.';
    }
    if (words.contains('memory') || words.contains('remember')) {
      return 'Persistent memory is planned for a later phase. In this version nothing you write is saved.';
    }
    if (words.contains('thanks') || words.contains('thank')) {
      return 'You are welcome! (This is a scripted demo reply.)';
    }

    final String reply = _fallbacks[_cursor % _fallbacks.length];
    _cursor++;
    return reply;
  }
}
