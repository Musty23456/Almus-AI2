import 'package:shared_preferences/shared_preferences.dart';

/// Bump when the wording below changes in a way that needs a new "yes".
const int kFaceConsentVersion = 1;

const String kFaceConsentTitle = 'Store your face data on this phone?';

/// Shown in full before anything is enrolled.
const String kFaceConsentText =
    'What is stored: a few "face templates" - lists of numbers computed from '
    'your face by a recognition model. They are not photographs, but they '
    'are biometric data and could be used to recognise you.\n\n'
    'What is not stored: the camera pictures. Each picture is deleted '
    'right after it has been processed.\n\n'
    'Where: only on this phone, encrypted, with a key kept in Android\'s '
    'secure key storage. Nothing is uploaded, and nothing is sent to Gemini '
    'or any backend.\n\n'
    'What it is used for: telling this app whether the face in front of the '
    'camera matches an enrolled person. It does NOT unlock the app and must '
    'not be used as a security check; the app lock stays with Android\'s own '
    'biometric prompt. It can be fooled by a photo or a video, and by '
    'someone who looks like you.\n\n'
    'Control: you can delete all face data at any time in this screen. '
    'Withdrawing consent deletes it immediately.';

class FaceConsent {
  const FaceConsent({required this.version, required this.grantedAt});

  final int version;
  final DateTime grantedAt;

  bool get isCurrent => version == kFaceConsentVersion;
}

abstract class FaceConsentStore {
  Future<FaceConsent?> read();
  Future<void> write(FaceConsent consent);
  Future<void> clear();
}

class MemoryFaceConsentStore implements FaceConsentStore {
  FaceConsent? value;

  @override
  Future<FaceConsent?> read() async => value;

  @override
  Future<void> write(FaceConsent consent) async => value = consent;

  @override
  Future<void> clear() async => value = null;
}

class PrefsFaceConsentStore implements FaceConsentStore {
  const PrefsFaceConsentStore();

  static const String _version = 'face_consent_version';
  static const String _at = 'face_consent_at';

  @override
  Future<FaceConsent?> read() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final int? v = p.getInt(_version);
    final String? at = p.getString(_at);
    if (v == null || at == null) return null;
    final DateTime? when = DateTime.tryParse(at);
    if (when == null) return null;
    return FaceConsent(version: v, grantedAt: when);
  }

  @override
  Future<void> write(FaceConsent consent) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_version, consent.version);
    await p.setString(_at, consent.grantedAt.toUtc().toIso8601String());
  }

  @override
  Future<void> clear() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_version);
    await p.remove(_at);
  }
}
