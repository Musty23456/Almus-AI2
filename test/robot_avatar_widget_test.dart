import 'package:almus_ai/avatar/avatar_profile.dart';
import 'package:almus_ai/models/robot_state.dart';
import 'package:almus_ai/widgets/robot_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduceMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('every state renders for several seconds without errors',
      (tester) async {
    for (final RobotState s in RobotState.values) {
      await tester.pumpWidget(_host(RobotAvatar(state: s, size: 200)));
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull, reason: s.name);
    }
  });

  testWidgets('switching state while animating does not throw',
      (tester) async {
    RobotState current = RobotState.idle;
    late StateSetter set;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            set = setState;
            return RobotAvatar(state: current);
          },
        ),
      ),
    );
    for (final RobotState s in RobotState.values) {
      set(() => current = s);
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('animates normally and stops its ticker with reduce motion',
      (tester) async {
    await tester.pumpWidget(_host(const RobotAvatar(state: RobotState.idle)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(
      _host(const RobotAvatar(state: RobotState.idle), reduceMotion: true),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    // Changing state in reduce-motion mode still works (static redraw).
    await tester.pumpWidget(
      _host(const RobotAvatar(state: RobotState.error), reduceMotion: true),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('frames are capped: painted frames stay below the 30 fps cap',
      (tester) async {
    await tester.pumpWidget(_host(const RobotAvatar(state: RobotState.idle)));
    final int before = AvatarRuntime.paintedFrames;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final int painted = AvatarRuntime.paintedFrames - before;
    // About 1 second of 60 Hz frames: must be well below 60 painted.
    expect(painted, lessThanOrEqualTo(34));
    expect(painted, greaterThan(15));
  });

  testWidgets('low power mode lowers the frame rate', (tester) async {
    await tester.pumpWidget(
      _host(const RobotAvatar(state: RobotState.idle, lowPower: true)),
    );
    final int before = AvatarRuntime.paintedFrames;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(AvatarRuntime.paintedFrames - before, lessThanOrEqualTo(24));
  });

  testWidgets('accepts a mouth level, tiny sizes and zero size',
      (tester) async {
    final ValueNotifier<double?> level = ValueNotifier<double?>(0.9);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            RobotAvatar(
              state: RobotState.talking,
              size: 52,
              mouthLevel: level,
            ),
            const RobotAvatar(state: RobotState.talking, size: 0),
          ],
        ),
      ),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    level.value = null;
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantics label names the state', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const RobotAvatar(state: RobotState.happy)));
    expect(
      find.bySemanticsLabel('Almus robot avatar. State: Happy'),
      findsOneWidget,
    );
    handle.dispose();
  });
}
