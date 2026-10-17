import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guards for the biometric privacy rules. They cannot prove the
/// absence of every leak, but they catch the common mistakes.
void main() {
  final List<File> files = <File>[
    ...Directory('lib/face')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart')),
    File('lib/screens/face_recognition_screen.dart'),
  ];

  test('there are face source files to check', () {
    expect(files.length, greaterThan(8));
  });

  test('face code never logs or prints', () {
    final RegExp logging =
        RegExp(r'(^|[^A-Za-z_])(print|debugPrint|log|debugPrintStack)\s*\(');
    for (final File f in files) {
      final String code = f
          .readAsLinesSync()
          .where((String l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(logging.hasMatch(code), isFalse, reason: f.path);
      expect(code.contains('developer.log'), isFalse, reason: f.path);
    }
  });

  test('face code has no network access', () {
    for (final File f in files) {
      final String code = f.readAsStringSync();
      expect(code.contains("package:http/"), isFalse, reason: f.path);
      expect(code.contains('HttpClient'), isFalse, reason: f.path);
      expect(code.contains('Socket'), isFalse, reason: f.path);
      expect(code.contains('backend_client'), isFalse, reason: f.path);
    }
  });

  test('face code does not touch the app lock', () {
    for (final File f in files) {
      final String code = f.readAsStringSync();
      expect(code.contains('security/app_lock_controller'), isFalse,
          reason: f.path);
      expect(code.contains('local_auth'), isFalse, reason: f.path);
    }
  });

  test('face code does not copy pictures into persistent storage', () {
    for (final File f in files) {
      final String code = f.readAsStringSync();
      expect(code.contains('.copy('), isFalse, reason: f.path);
      expect(code.contains('writeAsBytes(bytes'), isFalse, reason: f.path);
    }
  });

  test('the old Phase 9 screen that saved a photo is gone', () {
    expect(File('lib/screens/face_enrollment_screen.dart').existsSync(), isFalse);
  });

  // ---- Phase 6b: the cloud option ----
  // The on-device code above is checked non-recursively, so lib/face/cloud is a
  // separate, deliberate exception. It may use the network in ONE file only.
  final List<File> cloudFiles = Directory('lib/face/cloud')
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  test('cloud: only cloud_face_api.dart uses the network', () {
    expect(cloudFiles.length, greaterThan(3));
    for (final File f in cloudFiles) {
      final String code = f.readAsStringSync();
      final bool isApi = f.path.endsWith('cloud_face_api.dart');
      expect(code.contains('package:http/'), isApi, reason: f.path);
      expect(code.contains('HttpClient'), isFalse, reason: f.path);
      expect(code.contains('Socket'), isFalse, reason: f.path);
      expect(code.contains('backend_client'), isFalse, reason: f.path);
    }
  });

  test('cloud: never logs, never touches the app lock, never copies pictures', () {
    final RegExp logging =
        RegExp(r'(^|[^A-Za-z_])(print|debugPrint|log|debugPrintStack)\s*\(');
    for (final File f in cloudFiles) {
      final String code = f
          .readAsLinesSync()
          .where((String l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(logging.hasMatch(code), isFalse, reason: f.path);
      expect(code.contains('developer.log'), isFalse, reason: f.path);
      expect(code.contains('security/app_lock_controller'), isFalse, reason: f.path);
      expect(code.contains('local_auth'), isFalse, reason: f.path);
      expect(code.contains('.copy('), isFalse, reason: f.path);
      expect(code.contains('writeAsBytes'), isFalse, reason: f.path);
    }
  });

  test('on-device face code never imports the cloud code', () {
    for (final File f in files) {
      expect(f.readAsStringSync().contains('cloud/'), isFalse, reason: f.path);
      expect(f.readAsStringSync().contains('cloud_face'), isFalse, reason: f.path);
    }
  });

  test('cloud: no Luxand token or direct Luxand address in the app', () {
    for (final File f in <File>[
      ...cloudFiles,
      File('lib/screens/cloud_face_screen.dart'),
    ]) {
      final String code = f.readAsStringSync().toLowerCase();
      expect(code.contains('luxand.cloud/'), isFalse, reason: f.path);
      expect(code.contains('api.luxand'), isFalse, reason: f.path);
    }
  });
}
