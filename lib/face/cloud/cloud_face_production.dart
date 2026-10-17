import '../../models/app_settings.dart';
import '../face_adapters.dart';
import 'cloud_face_api.dart';
import 'cloud_face_controller.dart';
import 'cloud_face_storage.dart';

/// The real adapters for the cloud screen. [close] releases the detector and
/// the HTTP client.
({CloudFaceController controller, Future<void> Function() close})
    buildProductionCloudFace(AppSettings Function() settings) {
  final HttpCloudFaceApi api = HttpCloudFaceApi();
  final MlKitFaceDetectorPort detector = MlKitFaceDetectorPort();
  final CameraFacePort capture = CameraFacePort();
  final CloudFaceController controller = CloudFaceController(
    api: api,
    settings: settings,
    capture: capture,
    decoder: const ImagePackageDecoder(),
    detector: detector,
    linkStore: SecureCloudFaceLinkStore(),
    consentStore: const PrefsCloudFaceConsentStore(),
  );
  return (
    controller: controller,
    close: () async {
      api.close();
      await detector.close();
      await capture.close();
    },
  );
}
