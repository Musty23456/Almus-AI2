import 'dart:typed_data';

import 'package:almus_ai/face/face_consent.dart';
import 'package:almus_ai/face/face_ports.dart';
import 'package:almus_ai/screens/face_recognition_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'face_fakes.dart';

/// Lets the controllers' in-memory async work finish (fake time).
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> show(WidgetTester tester, Rig rig) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: FaceRecognitionScreen(dependencies: rig.dependencies()),
  ));
  await settle(tester);
}

void main() {
  testWidgets('without a model it says so and cannot scan or enrol',
      (WidgetTester tester) async {
    final Rig rig = Rig(manifest: testManifest(calibrated: false), soundEnabled: false);
    await show(tester, rig);
    expect(find.text('RECOGNITION UNAVAILABLE'), findsOneWidget);
    expect(find.text('IDENTITY VERIFIED'), findsNothing);
    expect(
        tester.widget<FilledButton>(find.byKey(const Key('start-scan'))).onPressed,
        isNull);
    expect(
        tester.widget<FilledButton>(find.byKey(const Key('enroll-button'))).onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the limits are visible and honest', (WidgetTester tester) async {
    final Rig rig = Rig(manifest: testManifest(calibrated: false), soundEnabled: false);
    await show(tester, rig);
    expect(find.textContaining('NO liveness'), findsOneWidget);
    expect(find.textContaining('not a lock'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the scanning sound switch is off by default and saves',
      (WidgetTester tester) async {
    final Rig rig = Rig(manifest: testManifest(calibrated: false), soundEnabled: false);
    await show(tester, rig);
    final SwitchListTile tile =
        tester.widget<SwitchListTile>(find.byKey(const Key('scan-sound-switch')));
    expect(tile.value, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a match shows the name only after matching',
      (WidgetTester tester) async {
    final Rig rig = Rig(soundEnabled: false);
    await tester.runAsync(() => rig.enrolOne('Amina', vec(1, 0, 0, 0)));
    await show(tester, rig);
    expect(find.text('READY TO SCAN'), findsOneWidget);
    expect(find.byKey(const Key('verified-name')), findsNothing);
    await tester.tap(find.byKey(const Key('start-scan')));
    await settle(tester);
    expect(find.text('IDENTITY VERIFIED'), findsOneWidget);
    expect(find.text('Matched: Amina'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unknown face is shown as unknown',
      (WidgetTester tester) async {
    final Rig rig = Rig(soundEnabled: false, embeddings: <Float32List>[vec(0, 0, 1, 0)]);
    await tester.runAsync(() => rig.enrolOne('Amina', vec(1, 0, 0, 0)));
    await show(tester, rig);
    await tester.tap(find.byKey(const Key('start-scan')));
    await settle(tester);
    expect(find.text('UNKNOWN IDENTITY'), findsOneWidget);
    expect(find.text('IDENTITY VERIFIED'), findsNothing);
    expect(find.byKey(const Key('verified-name')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('camera denied is shown as camera unavailable',
      (WidgetTester tester) async {
    final Rig rig = Rig(soundEnabled: false);
    rig.capture.status = CameraStatus.permissionDenied;
    await show(tester, rig);
    expect(find.text('CAMERA UNAVAILABLE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('enrolling asks for consent first and "no" stores nothing',
      (WidgetTester tester) async {
    final Rig rig = Rig(soundEnabled: false);
    await show(tester, rig);
    await tester.tap(find.byKey(const Key('enroll-button')));
    await tester.pumpAndSettle();
    expect(find.text(kFaceConsentTitle), findsOneWidget);
    await tester.tap(find.text('NO, CANCEL'));
    await tester.pumpAndSettle();
    expect(rig.consent.value, isNull);
    expect(rig.capture.captures, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('delete all removes enrolled faces after confirmation',
      (WidgetTester tester) async {
    final Rig rig = Rig(soundEnabled: false);
    await tester.runAsync(() => rig.enrolOne('Amina', vec(1, 0, 0, 0)));
    await show(tester, rig);
    expect(find.text('Amina'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DELETE'));
    await settle(tester);
    expect(find.text('Amina'), findsNothing);
    expect(await tester.runAsync(() => rig.vaultFile.exists()), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
