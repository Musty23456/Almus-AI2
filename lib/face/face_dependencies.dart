import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'face_adapters.dart';
import 'face_consent.dart';
import 'face_model_locator.dart';
import 'face_ports.dart';
import 'face_recognition_controller.dart';
import 'face_vault.dart';
import 'scan_sound.dart';

/// Everything the face screen needs, so tests can supply fakes.
class FaceDependencies {
  FaceDependencies({
    required this.runtime,
    required this.capture,
    required this.decoder,
    required this.detector,
    required this.vault,
    required this.consentStore,
    required this.sound,
  });

  final FaceRuntime runtime;
  final FaceCapturePort capture;
  final FaceImageDecoder decoder;
  final FaceDetectorPort detector;
  final FaceTemplateVault vault;
  final FaceConsentStore consentStore;
  final ScanSoundController sound;

  /// The real adapters. Also removes the Phase 9 face photo, if any.
  static Future<FaceDependencies> production() async {
    await const LegacyFaceSamplePurger().purge();
    final Directory dir = await getApplicationSupportDirectory();
    final ScanSoundController sound = ScanSoundController(
      player: AudioplayersScanSoundPlayer(),
      store: const PrefsScanSoundSettingsStore(),
    );
    await sound.load();
    return FaceDependencies(
      runtime: await buildFaceRuntime(),
      capture: CameraFacePort(),
      decoder: const ImagePackageDecoder(),
      detector: MlKitFaceDetectorPort(),
      vault: FaceTemplateVault(
        file: IoVaultFile('${dir.path}/almus_face_vault.bin'),
        keys: SecureStorageVaultKeyStore(),
      ),
      consentStore: const PrefsFaceConsentStore(),
      sound: sound,
    );
  }

  Future<void> dispose() async {
    sound.dispose();
    await detector.close();
    await capture.close();
  }
}
