import 'package:almus_ai/controllers/settings_controller.dart';
import 'package:almus_ai/face/cloud/cloud_face_api.dart';
import 'package:almus_ai/face/cloud/cloud_face_controller.dart';
import 'package:almus_ai/screens/cloud_face_screen.dart';
import 'package:almus_ai/services/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_face_fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<CloudFaceController> show(WidgetTester tester, Setup t) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final CloudFaceController c = t.controller();
  await tester.pumpWidget(MaterialApp(
    home: CloudFaceScreen(
      settings: SettingsController(MemorySettingsStore()),
      controller: c,
    ),
  ));
  await settle(tester);
  return c;
}

void main() {
  testWidgets('says plainly that it uploads, and that it is not a lock', (WidgetTester tester) async {
    await show(tester, Setup(consent: false, enrolled: false));
    expect(find.textContaining('UPLOADS face photos'), findsOneWidget);
    expect(find.textContaining('not a lock'), findsOneWidget);
    expect(find.byKey(const Key('cloud-nobody')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verify is disabled until someone is enrolled', (WidgetTester tester) async {
    await show(tester, Setup(consent: false, enrolled: false));
    expect(tester.widget<FilledButton>(find.byKey(const Key('cloud-verify'))).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('enrolling without consent asks first and sends nothing if declined', (WidgetTester tester) async {
    final Setup t = Setup(consent: false, enrolled: false);
    await show(tester, t);
    await tester.tap(find.byKey(const Key('cloud-enroll')));
    await settle(tester);
    expect(find.text('Send your face photos to the cloud?'), findsOneWidget);
    expect(find.textContaining('Luxand.cloud'), findsWidgets);
    await tester.tap(find.text('NO, CANCEL'));
    await settle(tester);
    expect(t.api.calls, isEmpty);
    expect(t.capture.opens, 0);
    expect(t.consentStore.value, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed cloud delete is shown as NOT deleted', (WidgetTester tester) async {
    final Setup t = Setup()..api.removeError = const CloudFaceException('network', 'offline');
    await show(tester, t);
    await tester.tap(find.byKey(const Key('cloud-delete')));
    await settle(tester);
    await tester.tap(find.text('DELETE'));
    await settle(tester);
    expect(find.textContaining('NOT deleted'), findsOneWidget);
    expect(find.byKey(const Key('cloud-enrolled-name')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a verified result shows the name only in the verified state', (WidgetTester tester) async {
    final Setup t = Setup();
    final CloudFaceController c = await show(tester, t);
    expect(find.byKey(const Key('cloud-verified-name')), findsNothing);
    await c.verify();
    await settle(tester);
    expect(find.text('IDENTITY VERIFIED'), findsOneWidget);
    expect(find.byKey(const Key('cloud-verified-name')), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    expect(find.byKey(const Key('cloud-verified-name')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
