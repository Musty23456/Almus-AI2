import 'dart:async';

import 'package:almus_ai/app.dart';
import 'package:almus_ai/screens/lock_screen.dart';
import 'package:almus_ai/security/app_lock_controller.dart';
import 'package:almus_ai/security/biometric_service.dart';
import 'package:almus_ai/services/demo_chat_service.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:almus_ai/widgets/app_lock_gate.dart';
import 'package:almus_ai/widgets/biometric_eye_scanner.dart';
import 'package:almus_ai/widgets/security_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lock_fakes.dart';

void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

/// The eye animation repeats forever, so tests advance time by hand
/// instead of waiting for everything to settle.
Future<void> _advance(WidgetTester tester, [int steps = 4]) async {
  for (int i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('BiometricEyeScanner', () {
    for (final EyeScannerState state in EyeScannerState.values) {
      testWidgets('draws the ${state.name} state', (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(home: Center(child: BiometricEyeScanner(state: state))),
        );
        await _advance(tester);
        expect(find.byType(BiometricEyeScanner), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('switches state and respects reduced motion',
        (WidgetTester tester) async {
      EyeScannerState state = EyeScannerState.idle;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                update = setState;
                return Center(child: BiometricEyeScanner(state: state));
              },
            ),
          ),
        ),
      );
      update(() => state = EyeScannerState.scanning);
      await _advance(tester);
      update(() => state = EyeScannerState.verified);
      await _advance(tester);
      expect(tester.takeException(), isNull);
    });

    test('every state has its own accent colour', () {
      final Set<Color> colours = EyeScannerState.values
          .map(BiometricEyeScanner.colorFor)
          .toSet();
      expect(colours.length, greaterThanOrEqualTo(4));
    });
  });

  group('LockScreen', () {
    testWidgets('explains an unavailable phone and offers to continue',
        (WidgetTester tester) async {
      _usePhoneScreen(tester);
      final AppLockController c = makeLockController(
        FakeBiometricService(caps: BiometricCapabilities.none),
      );
      await c.load();
      await tester.pumpWidget(MaterialApp(home: LockScreen(controller: c)));
      await _advance(tester);

      expect(find.text('ALMUS AI SECURITY'), findsOneWidget);
      expect(find.text('BIOMETRICS UNAVAILABLE'), findsOneWidget);
      expect(find.byKey(const Key('lock_continue_without')), findsOneWidget);
      // Nothing to authenticate with, so no authenticate button.
      expect(find.byKey(const Key('lock_authenticate')), findsNothing);
    });

    testWidgets('shows the failed state and a retry button',
        (WidgetTester tester) async {
      _usePhoneScreen(tester);
      final AppLockController c = makeLockController(
        FakeBiometricService(script: <AuthOutcome>[AuthOutcome.failed]),
      );
      await c.load();
      await tester.pumpWidget(MaterialApp(home: LockScreen(controller: c)));
      await _advance(tester);

      expect(find.text('AUTHENTICATION FAILED'), findsOneWidget);
      expect(find.text('TRY AGAIN'), findsOneWidget);
      expect(find.byKey(const Key('lock_fallback')), findsOneWidget);
    });

    test('every state has a label and a scanner state', () {
      for (final AppLockState s in AppLockState.values) {
        expect(LockScreen.statusLabel(s), isNotEmpty);
        expect(LockScreen.scannerFor(s), isA<EyeScannerState>());
      }
    });
  });

  group('AppLockGate', () {
    testWidgets('private content never exists while locked and hides again',
        (WidgetTester tester) async {
      _usePhoneScreen(tester);
      final FakeBiometricService fake = FakeBiometricService()
        ..hold = Completer<AuthOutcome>();
      final AppLockController c = makeLockController(fake);

      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              AppLockGate(controller: c, child: child!),
          home: const Scaffold(body: Text('PRIVATE')),
        ),
      );
      // Before the settings are even loaded: lock screen only.
      expect(find.text('PRIVATE'), findsNothing);
      expect(find.text('ALMUS AI SECURITY'), findsOneWidget);

      unawaited(c.load());
      await _advance(tester);
      expect(find.text('PRIVATE'), findsNothing);
      expect(find.text('WAITING FOR ANDROID SECURITY'), findsOneWidget);

      // Android says yes.
      fake.hold!.complete(AuthOutcome.success);
      await _advance(tester);
      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.text('ALMUS AI SECURITY'), findsNothing);

      // Backgrounded: locked immediately and hidden.
      fake.hold = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(c.privateContentVisible, isFalse);

      // Back in the foreground: Android is asked again (it says no).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _advance(tester);
      expect(find.text('PRIVATE'), findsNothing);
      expect(find.text('AUTHENTICATION FAILED'), findsOneWidget);
    });
  });

  group('whole app', () {
    testWidgets('chat, memory and settings are unreachable until unlocked',
        (WidgetTester tester) async {
      _usePhoneScreen(tester);
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.failed],
      );
      final AppLockController c = makeLockController(fake);

      await tester.pumpWidget(
        AlmusApp(
          showSplash: false,
          chatService: DemoChatService(thinkingDelay: Duration.zero),
          settingsStore: MemorySettingsStore(),
          appLock: c,
        ),
      );
      await _advance(tester);

      expect(find.text('AUTHENTICATION FAILED'), findsOneWidget);
      expect(find.text('Welcome back'), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      expect(find.byIcon(Icons.psychology_outlined), findsNothing);

      fake.script.add(AuthOutcome.success);
      await tester.tap(find.byKey(const Key('lock_authenticate')));
      await _advance(tester, 6);

      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('AUTHENTICATION FAILED'), findsNothing);
    });
  });

  group('SecuritySettingsCard', () {
    Future<(AppLockController, FakeBiometricService)> pumpCard(
      WidgetTester tester,
    ) async {
      _usePhoneScreen(tester);
      final FakeBiometricService fake = FakeBiometricService(
        script: <AuthOutcome>[AuthOutcome.success],
      );
      final AppLockController c = makeLockController(fake);
      await c.load();
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SecuritySettingsCard(controller: c),
            ),
          ),
        ),
      );
      expect(c.privateContentVisible, isTrue);
      return (c, fake);
    }

    testWidgets('switching the lock off asks Android and can be refused',
        (WidgetTester tester) async {
      final (AppLockController c, FakeBiometricService fake) =
          await pumpCard(tester);

      fake.script.add(AuthOutcome.failed);
      await tester.tap(find.byKey(const Key('lock_enabled_switch')));
      await _advance(tester);

      expect(c.settings.enabled, isTrue);
      expect(find.byKey(const Key('lock_settings_message')), findsOneWidget);

      fake.script.add(AuthOutcome.success);
      await tester.tap(find.byKey(const Key('lock_enabled_switch')));
      await _advance(tester);

      expect(c.settings.enabled, isFalse);
    });

    testWidgets('"Test biometric availability" reports the current state',
        (WidgetTester tester) async {
      final (AppLockController _, FakeBiometricService fake) =
          await pumpCard(tester);

      fake.caps = BiometricCapabilities.none;
      await tester.tap(find.byKey(const Key('lock_test_button')));
      await _advance(tester);

      expect(
        find.textContaining('Authentication is possible: no'),
        findsOneWidget,
      );
    });
  });
}
