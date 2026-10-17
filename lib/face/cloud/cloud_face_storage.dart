import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bump when the wording below changes in a way that needs a new "yes".
const int kCloudFaceConsentVersion = 1;

const String kCloudFaceConsentTitle = 'Send your face photos to the cloud?';

/// Shown in full before anything is captured for cloud verification.
const String kCloudFaceConsentText =
    'This is DIFFERENT from the on-device face feature, which never uploads '
    'anything.\n\n'
    'What is sent: short face photos from your front camera. They go to YOUR '
    'Almus backend, which forwards them to Luxand.cloud, a third-party face '
    'service. The service keeps your face data on its servers so it can '
    'compare later photos with it.\n\n'
    'What this phone keeps: only a name you choose and an anonymous person id, '
    'in Android\'s secure key storage. Camera photos are deleted right after '
    'they are sent. No real name is sent to the service.\n\n'
    'What it is for: checking whether the person in front of the camera is the '
    'one enrolled (a one-to-one check). It does NOT replace the app lock, which '
    'stays with Android\'s own biometric prompt.\n\n'
    'Limits: it has no proven protection against a printed photo, a picture on '
    'another screen or a replayed video. It needs internet. Its rules, price '
    'and how long the service keeps data are set by that service, not by this '
    'app. Only enrol yourself, or someone who agreed: biometric laws may apply '
    'to you.\n\n'
    'Control: you can delete your face from the service and from this phone at '
    'any time here. Withdrawing consent does the same. If the service cannot '
    'be reached, deletion is NOT reported as done.';

class CloudFaceConsent {
  const CloudFaceConsent({required this.version, required this.grantedAt});

  final int version;
  final DateTime grantedAt;

  bool get isCurrent => version == kCloudFaceConsentVersion;
}

abstract class CloudFaceConsentStore {
  Future<CloudFaceConsent?> read();
  Future<void> write(CloudFaceConsent consent);
  Future<void> clear();
}

class MemoryCloudFaceConsentStore implements CloudFaceConsentStore {
  CloudFaceConsent? value;

  @override
  Future<CloudFaceConsent?> read() async => value;

  @override
  Future<void> write(CloudFaceConsent consent) async => value = consent;

  @override
  Future<void> clear() async => value = null;
}

class PrefsCloudFaceConsentStore implements CloudFaceConsentStore {
  const PrefsCloudFaceConsentStore();

  static const String _version = 'cloud_face_consent_version';
  static const String _at = 'cloud_face_consent_at';

  @override
  Future<CloudFaceConsent?> read() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final int? v = p.getInt(_version);
    final String? at = p.getString(_at);
    if (v == null || at == null) return null;
    final DateTime? when = DateTime.tryParse(at);
    if (when == null) return null;
    return CloudFaceConsent(version: v, grantedAt: when);
  }

  @override
  Future<void> write(CloudFaceConsent consent) async {
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

/// The one enrolled person: a label the user chose and the service's anonymous
/// person id. There are no embeddings and no pictures here.
class CloudFaceLink {
  const CloudFaceLink({required this.name, required this.personId, required this.createdAt});

  final String name;
  final String personId;
  final DateTime createdAt;
}

abstract class CloudFaceLinkStore {
  Future<CloudFaceLink?> read();
  Future<void> write(CloudFaceLink link);
  Future<void> clear();
}

class MemoryCloudFaceLinkStore implements CloudFaceLinkStore {
  CloudFaceLink? value;
  bool failWrites = false;

  @override
  Future<CloudFaceLink?> read() async => value;

  @override
  Future<void> write(CloudFaceLink link) async {
    if (failWrites) throw StateError('write failed');
    value = link;
  }

  @override
  Future<void> clear() async => value = null;
}

/// Android Keystore-backed secure storage.
class SecureCloudFaceLinkStore implements CloudFaceLinkStore {
  SecureCloudFaceLinkStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _name = 'almus_cloud_face_link_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<CloudFaceLink?> read() async {
    final String? text = await _storage.read(key: _name);
    if (text == null) return null;
    try {
      final Object? root = jsonDecode(text);
      if (root is! Map<String, dynamic>) return null;
      final Object? name = root['name'];
      final Object? id = root['id'];
      final Object? created = root['created'];
      if (name is! String || id is! String || created is! String) return null;
      final DateTime? when = DateTime.tryParse(created);
      if (when == null) return null;
      return CloudFaceLink(name: name, personId: id, createdAt: when);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(CloudFaceLink link) => _storage.write(
        key: _name,
        value: jsonEncode(<String, String>{
          'name': link.name,
          'id': link.personId,
          'created': link.createdAt.toUtc().toIso8601String(),
        }),
      );

  @override
  Future<void> clear() => _storage.delete(key: _name);
}
