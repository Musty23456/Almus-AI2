import 'dart:async';
import 'dart:typed_data';

import 'package:almus_ai/face/cloud/cloud_face_api.dart';
import 'package:almus_ai/face/cloud/cloud_face_controller.dart';
import 'package:almus_ai/face/cloud/cloud_face_storage.dart';
import 'package:almus_ai/face/face_ports.dart';
import 'package:almus_ai/models/app_settings.dart';

import 'face_fakes.dart';

const String kId = '123e4567-e89b-12d3-a456-426614174000';
const String kId2 = '223e4567-e89b-12d3-a456-426614174000';

/// A scripted backend. Nothing here talks to a network or to Luxand.
class FakeCloudApi implements CloudFaceApi {
  final List<String> calls = <String>[];
  Object? enrollError;
  Object? addPhotoError;
  Object? verifyError;
  Object? removeError;
  bool verifyResult = true;
  Completer<bool>? verifyGate;
  int enrollCount = 0;
  List<String> removed = <String>[];

  @override
  Future<CloudFaceStatus> status(AppSettings settings) async {
    calls.add('status');
    return const CloudFaceStatus(available: true, calibrated: true);
  }

  @override
  Future<String> enroll(AppSettings settings, Uint8List jpeg) async {
    calls.add('enroll');
    if (enrollError != null) throw enrollError!;
    enrollCount++;
    return enrollCount == 1 ? kId : kId2;
  }

  @override
  Future<void> addPhoto(AppSettings settings, String personId, Uint8List jpeg) async {
    calls.add('addPhoto');
    if (addPhotoError != null) throw addPhotoError!;
  }

  @override
  Future<bool> verify(AppSettings settings, String personId, Uint8List jpeg) async {
    calls.add('verify:$personId');
    if (verifyError != null) throw verifyError!;
    if (verifyGate != null) return verifyGate!.future;
    return verifyResult;
  }

  @override
  Future<void> remove(AppSettings settings, String personId) async {
    calls.add('remove:$personId');
    if (removeError != null) throw removeError!;
    removed.add(personId);
  }
}

class Setup {
  Setup({AppSettings? settings, bool consent = true, bool enrolled = true})
      : settings = settings ??
            const AppSettings(backendUrl: 'https://backend.example', accessToken: 'tok') {
    if (consent) {
      consentStore.value = CloudFaceConsent(
          version: kCloudFaceConsentVersion, grantedAt: DateTime.utc(2026, 1, 1));
    }
    if (enrolled) {
      links.value = CloudFaceLink(
          name: 'Musty', personId: kId, createdAt: DateTime.utc(2026, 1, 1));
    }
  }

  final AppSettings settings;
  final FakeCloudApi api = FakeCloudApi();
  final FakeCapture capture = FakeCapture();
  final FakeDecoder decoder = FakeDecoder();
  final FakeDetector detector = FakeDetector();
  final MemoryCloudFaceLinkStore links = MemoryCloudFaceLinkStore();
  final MemoryCloudFaceConsentStore consentStore = MemoryCloudFaceConsentStore();

  CloudFaceController controller({Duration timeout = const Duration(milliseconds: 300)}) =>
      CloudFaceController(
        api: api,
        settings: () => settings,
        capture: capture,
        decoder: decoder,
        detector: detector,
        linkStore: links,
        consentStore: consentStore,
        captureTimeout: timeout,
        attemptPause: const Duration(milliseconds: 5),
        resultVisible: const Duration(seconds: 8),
        readFrame: (CapturedFrame f) async => Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]),
      );
}
