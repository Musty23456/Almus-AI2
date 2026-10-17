import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/app_settings.dart';

/// Why a cloud face request failed, in words that are safe to show.
class CloudFaceException implements Exception {
  const CloudFaceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CloudFaceException($code)';
}

class CloudFaceStatus {
  const CloudFaceStatus({required this.available, required this.calibrated});

  final bool available;
  final bool calibrated;
}

/// The backend's /v1/face/* routes. The Luxand token never reaches the app:
/// only the backend address and APP_ACCESS_TOKEN are used here.
abstract class CloudFaceApi {
  Future<CloudFaceStatus> status(AppSettings settings);

  /// Creates a person from one JPEG and returns the person id.
  Future<String> enroll(AppSettings settings, Uint8List jpeg);

  Future<void> addPhoto(AppSettings settings, String personId, Uint8List jpeg);

  /// 1:1 check against ONE enrolled person. True only when the backend says
  /// verified; anything unclear is an exception or false, never true.
  Future<bool> verify(AppSettings settings, String personId, Uint8List jpeg);

  /// Deletes the person at the service. Completes only if it was deleted.
  Future<void> remove(AppSettings settings, String personId);
}

class HttpCloudFaceApi implements CloudFaceApi {
  HttpCloudFaceApi({http.Client? client, this.timeout = const Duration(seconds: 45)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  void close() => _client.close();

  @override
  Future<CloudFaceStatus> status(AppSettings settings) async {
    final Map<String, dynamic> json = await _send(settings, 'GET', '/v1/face/status');
    return CloudFaceStatus(
      available: json['available'] == true,
      calibrated: json['calibrated'] == true,
    );
  }

  @override
  Future<String> enroll(AppSettings settings, Uint8List jpeg) async {
    final Map<String, dynamic> json = await _send(
      settings,
      'POST',
      '/v1/face/person',
      body: <String, dynamic>{'photo': base64Encode(jpeg)},
    );
    final Object? uuid = json['uuid'];
    if (uuid is! String || uuid.length != 36) {
      throw const CloudFaceException(
          'invalid_response', 'The backend sent a response the app could not understand.');
    }
    return uuid;
  }

  @override
  Future<void> addPhoto(AppSettings settings, String personId, Uint8List jpeg) async {
    await _send(
      settings,
      'POST',
      '/v1/face/person/${Uri.encodeComponent(personId)}/photos',
      body: <String, dynamic>{'photo': base64Encode(jpeg)},
    );
  }

  @override
  Future<bool> verify(AppSettings settings, String personId, Uint8List jpeg) async {
    final Map<String, dynamic> json = await _send(
      settings,
      'POST',
      '/v1/face/person/${Uri.encodeComponent(personId)}/verify',
      body: <String, dynamic>{'photo': base64Encode(jpeg)},
    );
    final Object? verified = json['verified'];
    if (verified is! bool) {
      // Fail closed: no clear "true" means no match.
      throw const CloudFaceException(
          'invalid_response', 'The backend sent a response the app could not understand.');
    }
    return verified;
  }

  @override
  Future<void> remove(AppSettings settings, String personId) async {
    final Map<String, dynamic> json = await _send(
      settings,
      'DELETE',
      '/v1/face/person/${Uri.encodeComponent(personId)}',
    );
    if (json['deleted'] != true) {
      throw const CloudFaceException(
          'delete_failed', 'The face could not be deleted from the cloud service.');
    }
  }

  Future<Map<String, dynamic>> _send(
    AppSettings settings,
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final String? base = normalizeBackendUrl(settings.backendUrl);
    if (base == null) {
      throw const CloudFaceException(
          'not_configured', 'Set a valid https:// backend address in Settings first.');
    }
    if (settings.accessToken.isEmpty) {
      throw const CloudFaceException(
          'not_configured', 'Cloud face verification needs your access token in Settings.');
    }
    final Uri uri = Uri.parse('$base$path');
    final Map<String, String> headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${settings.accessToken}',
    };
    if (body != null) headers['content-type'] = 'application/json';

    final http.Response response;
    try {
      final Future<http.Response> request = switch (method) {
        'POST' => _client.post(uri, headers: headers, body: jsonEncode(body)),
        'DELETE' => _client.delete(uri, headers: headers),
        _ => _client.get(uri, headers: headers),
      };
      response = await request.timeout(timeout);
    } on TimeoutException {
      throw const CloudFaceException('timeout',
          'The backend took too long to answer. If it runs on free hosting it may be waking up, so try again in a minute.');
    } on Exception {
      throw const CloudFaceException('network',
          'Could not reach the backend. Check your internet connection and the backend address in Settings.');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, dynamic>) return decoded;
      throw const CloudFaceException(
          'invalid_response', 'The backend sent a response the app could not understand.');
    }
    throw _errorFor(response.statusCode, decoded);
  }

  CloudFaceException _errorFor(int status, Object? decoded) {
    String? code;
    String? message;
    if (decoded is Map<String, dynamic>) {
      final Object? error = decoded['error'];
      if (error is Map<String, dynamic>) {
        if (error['code'] is String) code = error['code'] as String;
        if (error['message'] is String) message = error['message'] as String;
      }
    }
    code ??= 'http_$status';
    switch (code) {
      case 'unauthorized':
        return const CloudFaceException(
            'unauthorized', 'The access token was rejected. Check it in Settings.');
      case 'face_not_usable':
        return const CloudFaceException('face_not_usable',
            'The service could not use that photo. Make sure one clear face is in view.');
      case 'face_not_calibrated':
        return const CloudFaceException('face_not_calibrated',
            'Matching is switched off on the backend until a similarity threshold is set.');
      case 'face_not_configured':
        return const CloudFaceException(
            'face_not_configured', 'Cloud face verification is not set up on the backend.');
      case 'face_requires_access_token':
        return const CloudFaceException('face_requires_access_token',
            'The backend needs APP_ACCESS_TOKEN set before face routes work.');
      case 'rate_limited':
      case 'daily_limit_reached':
        return CloudFaceException(code, 'Too many face requests. Try again later.');
      default:
        return CloudFaceException(
          code,
          (message != null && message.length <= 200)
              ? message
              : 'The face service had a problem. Please try again.',
        );
    }
  }
}
