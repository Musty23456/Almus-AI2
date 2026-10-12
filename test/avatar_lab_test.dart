import 'package:almus_ai/app.dart';
import 'package:almus_ai/avatar/avatar_profile.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/screens/avatar_lab_screen.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _openLab(WidgetTester tester) async {
  _usePhoneScreen(tester);
  await tester.pumpWidget(
    AlmusApp(
      showSplash: false,
      chatService: DemoChatService(thinkingDelay: Duration.zero),
      settingsStore: MemorySettingsStore(),
    ),
  );
  await tester.pump();
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));

  expect(find.byKey(const Key('avatar_lab_tile')), findsNothing);
  for (int i = 0; i < 7; i++) {
    await tester.tap(find.byKey(const Key('version_row')));
    await tester.pump();
  }
  expect(find.byKey(const Key('avatar_lab_tile')), findsOneWidget);
  await tester.tap(find.byKey(const Key('avatar_lab_tile')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    AvatarLabScreen.unlocked.value = false;
    AvatarRuntime.lowPower.value = false;
  });
  tearDown(() {
    AvatarLabScreen.unlocked.value = false;
    AvatarRuntime.lowPower.value = false;
  });

  testWidgets('Avatar Lab is hidden until the version is tapped 7 times',
      (tester) async {
    await _openLab(tester);
    expect(find.text('Avatar Lab'), findsWidgets);
    for (final RobotState s in RobotState.values) {
      expect(find.byKey(Key('lab_state_${s.name}')), findsOneWidget);
    }
  });

  testWidgets('lab can select each state', (tester) async {
    await _openLab(tester);
    for (final RobotState s in RobotState.values) {
      await tester.tap(find.byKey(Key('lab_state_${s.name}')));
      await tester.pump();
      expect(find.text('ROBOT STATE · ${s.label.toUpperCase()}'),
          findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-cycle moves to the next state', (tester) async {
    await _openLab(tester);
    await tester.tap(find.byKey(const Key('lab_cycle_switch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('ROBOT STATE · LISTENING'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lab_cycle_switch')));
    await tester.pump();
  });

  testWidgets('low power and manual mouth controls work', (tester) async {
    await _openLab(tester);
    await tester.tap(find.byKey(const Key('lab_lowpower_switch')));
    await tester.pump();
    expect(AvatarRuntime.lowPower.value, isTrue);

    await tester.tap(find.byKey(const Key('lab_mouth_switch')));
    await tester.pump();
    expect(find.byKey(const Key('lab_mouth_slider')), findsOneWidget);
    await tester.tap(find.byKey(const Key('lab_state_talking')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('simulated missing asset falls back to defaults',
      (tester) async {
    await _openLab(tester);
    await tester.tap(find.byKey(const Key('lab_simulate_missing')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('built-in defaults'), findsOneWidget);
    expect(find.byKey(const Key('lab_state_error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
