import 'package:almus_ai/app.dart';
import 'package:almus_ai/controllers/chat_controller.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/utils/formatters.dart';
import 'package:almus_ai/widgets/robot_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app() => AlmusApp(
      showSplash: false,
      chatService: DemoChatService(thinkingDelay: Duration.zero),
    );

/// Gives the test a tall phone-like screen so list items are all built.
void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test('formatTime pads hours and minutes', () {
    expect(formatTime(DateTime(2026, 1, 1, 9, 5)), '09:05');
    expect(formatTime(DateTime(2026, 1, 1, 18, 30)), '18:30');
  });

  testWidgets('splash screen leads to the home screen', (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(const AlmusApp());
    expect(find.text('ALMUS AI'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('home shows the avatar and lets you preview robot states',
      (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byType(RobotAvatar), findsOneWidget);
    expect(find.text('ROBOT STATE · IDLE'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Thinking'));
    await tester.pump();
    expect(find.text('ROBOT STATE · THINKING'), findsOneWidget);
  });

  testWidgets('quick action opens chat with DEMO MODE label and empty state',
      (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();

    await tester.tap(find.byKey(const Key('quick_start_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Start a conversation'), findsOneWidget);
    expect(find.textContaining('DEMO MODE'), findsWidgets);
  });

  testWidgets('sending a message shows a demo reply and the robot calms down',
      (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ALMUS · DEMO'), findsOneWidget);

    // Let the talking state expire so no timers stay pending.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('IDLE'), findsOneWidget);
  });

  testWidgets('/error shows the error state in the chat', (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.enterText(find.byKey(const Key('chat_input')), '/error');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('ALMUS · ERROR'), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('clear chat removes messages after confirmation',
      (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await _openTab(tester, Icons.chat_bubble_outline);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 6));

    await tester.tap(find.byKey(const Key('clear_chat_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('confirm_clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Start a conversation'), findsOneWidget);
  });

  testWidgets('memory screen explains that memory is not available yet',
      (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await _openTab(tester, Icons.psychology_outlined);

    expect(find.text('No memories yet'), findsOneWidget);
    expect(find.textContaining('later phase'), findsWidgets);
  });

  testWidgets('settings screen shows the app version', (tester) async {
    _usePhoneScreen(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await _openTab(tester, Icons.settings_outlined);

    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('DEMO MODE (simulated)'), findsOneWidget);
  });

  testWidgets('ChatController moves thinking -> talking -> idle',
      (tester) async {
    final ChatController controller = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );
    final List<RobotState> states = <RobotState>[];
    controller.robotState.addListener(
      () => states.add(controller.robotState.value),
    );

    controller.send('hello');
    expect(controller.messages.length, 1);
    expect(controller.isBusy, isTrue);

    await tester.pump(const Duration(milliseconds: 10));
    expect(controller.messages.length, 2);
    expect(controller.robotState.value, RobotState.talking);

    await tester.pump(const Duration(seconds: 6));
    expect(
      states,
      <RobotState>[
        RobotState.thinking,
        RobotState.talking,
        RobotState.idle,
      ],
    );

    controller.clear();
    expect(controller.messages, isEmpty);
    controller.dispose();
  });

  testWidgets('ChatController reflects typing as listening', (tester) async {
    final ChatController controller = ChatController(
      service: DemoChatService(thinkingDelay: Duration.zero),
    );

    controller.userTyping(true);
    expect(controller.robotState.value, RobotState.listening);
    controller.userTyping(false);
    expect(controller.robotState.value, RobotState.idle);

    controller.dispose();
  });
}
