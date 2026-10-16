import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'backup_models.dart';

/// PBKDF2 work factor used for new encrypted backups (OWASP 2023 guidance for
/// PBKDF2-HMAC-SHA256). Stored in every file, so it can be raised later.
const int kDefaultKdfIterations = 600000;

/// Smallest work factor accepted when creating a backup.
const int kMinCreateIterations = 100000;

/// Work factor limits accepted when READING a file (protects against files
/// that would make the phone compute for minutes).
const int kMinReadIterations = 1000;
const int kMaxReadIterations = 5000000;

const int kMinPasswordLength = 8;
const int kEnvelopeVersion = 1;

const List<int> _magic = <int>[0x41, 0x4C, 0x4D, 0x55, 0x53, 0x45, 0x4E, 0x43]; // ALMUSENC
const int _saltLength = 16;
const int _nonceLength = 12;
const int _tagLength = 16;
const int _maxHeaderLength = 4096;

/// What can be read from an encrypted backup without the password.
class EncryptedBackupInfo {
  const EncryptedBackupInfo({
    required this.iterations,
    required this.appVersion,
    required this.createdAt,
  });

  final int iterations;
  final String appVersion;
  final DateTime? createdAt;
}

/// Encrypts and decrypts backup archives.
///
/// Scheme: key = PBKDF2-HMAC-SHA256(password, random 16-byte salt, N
/// iterations) -> 256 bits; cipher = AES-256-GCM with a random 12-byte nonce.
/// The whole file prefix (magic, version, header JSON) is authenticated as
/// additional data, so changing the header (for example lowering the
/// iteration count) makes decryption fail. The password and key are never
/// written anywhere.
class BackupCrypto {
  BackupCrypto({Random? random, this.useIsolate = true})
      : iterations = kDefaultKdfIterations,
        _testing = false,
        _random = random ?? Random.secure();

  /// Lets tests use a small work factor. Never use in the app.
  @visibleForTesting
  BackupCrypto.forTesting({
    required this.iterations,
    Random? random,
    this.useIsolate = false,
  })  : _testing = true,
        _random = random ?? Random.secure();

  final int iterations;
  final bool _testing;
  final bool useIsolate;
  final Random _random;

  /// True when [bytes] start with the encrypted-backup signature.
  static bool looksEncrypted(Uint8List bytes) {
    if (bytes.length < _magic.length + 5) return false;
    for (int i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  static String? passwordProblem(String password) {
    if (password.length < kMinPasswordLength) {
      return 'Use a password of at least $kMinPasswordLength characters.';
    }
    return null;
  }

  List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _random.nextInt(256));

  /// Encrypts [plain] (a ZIP backup). The password is used exactly as typed.
  Future<Uint8List> encrypt(
    Uint8List plain,
    String password, {
    required String appVersion,
    required DateTime now,
  }) async {
    final String? problem = passwordProblem(password);
    if (problem != null) {
      throw BackupException(problem, BackupErrorCode.weakPassword);
    }
    if (iterations < kMinCreateIterations && !_testing) {
      throw const BackupException(
        'The encryption work factor is too low.',
        BackupErrorCode.weakPassword,
      );
    }
    final List<int> salt = _randomBytes(_saltLength);
    final List<int> nonce = _randomBytes(_nonceLength);
    final Uint8List prefix = _buildPrefix(<String, Object?>{
      'format': kEncryptedFormatId,
      'envelope_version': kEnvelopeVersion,
      'cipher': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'kdf_iterations': iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'inner': 'almus-ai-backup-zip',
      'app_version': appVersion,
      'created_at': isoTime(now),
    });
    final List<int> keyBytes =
        await _deriveKey(password, salt, iterations, useIsolate);
    final SecretBox box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: prefix,
    );
    final BytesBuilder out = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Decrypts a file made by [encrypt]. Throws a [BackupException] for a wrong
  /// password, a damaged file or an unsupported header; nothing else happens.
  Future<Uint8List> decrypt(Uint8List data, String password) async {
    final _ParsedEnvelope env = _parse(data);
    if (password.isEmpty) {
      throw const BackupException(
        'This backup is password-protected. Enter its password.',
        BackupErrorCode.passwordRequired,
      );
    }
    final List<int> keyBytes =
        await _deriveKey(password, env.salt, env.iterations, useIsolate);
    try {
      final List<int> clear = await AesGcm.with256bits().decrypt(
        SecretBox(env.cipherText, nonce: env.nonce, mac: Mac(env.tag)),
        secretKey: SecretKey(keyBytes),
        aad: env.prefix,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupException(
        'The password is incorrect, or the backup file is damaged.',
        BackupErrorCode.wrongPassword,
      );
    }
  }

  /// Reads the public header (no password needed).
  static EncryptedBackupInfo? readInfo(Uint8List data) {
    try {
      final _ParsedEnvelope env = _parse(data);
      return EncryptedBackupInfo(
        iterations: env.iterations,
        appVersion: env.appVersion,
        createdAt: env.createdAt,
      );
    } on BackupException {
      return null;
    }
  }

  static Uint8List _buildPrefix(Map<String, Object?> header) {
    final Uint8List headerBytes = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(kEnvelopeVersion)
      ..add(<int>[
        (headerBytes.length >> 24) & 0xFF,
        (headerBytes.length >> 16) & 0xFF,
        (headerBytes.length >> 8) & 0xFF,
        headerBytes.length & 0xFF,
      ])
      ..add(headerBytes);
    return b.toBytes();
  }

  static _ParsedEnvelope _parse(Uint8List data) {
    const BackupException damaged = BackupException(
      'This encrypted backup is damaged or incomplete.',
      BackupErrorCode.corrupted,
    );
    if (!looksEncrypted(data)) throw damaged;
    final int version = data[_magic.length];
    if (version != kEnvelopeVersion) {
      throw const BackupException(
        'This encrypted backup was made by a newer version of ALMUS AI. Update the app and try again.',
        BackupErrorCode.unsupportedVersion,
      );
    }
    final int lengthAt = _magic.length + 1;
    final int headerLength = (data[lengthAt] << 24) |
        (data[lengthAt + 1] << 16) |
        (data[lengthAt + 2] << 8) |
        data[lengthAt + 3];
    final int headerStart = lengthAt + 4;
    final int headerEnd = headerStart + headerLength;
    if (headerLength <= 0 ||
        headerLength > _maxHeaderLength ||
        headerEnd + _tagLength > data.length) {
      throw damaged;
    }
    final Map<String, Object?> header;
    try {
      header = asJsonMap(
        jsonDecode(utf8.decode(data.sublist(headerStart, headerEnd))),
        'header',
      );
    } on Object {
      throw damaged;
    }
    if (header['format'] != kEncryptedFormatId ||
        header['cipher'] != 'AES-256-GCM' ||
        header['kdf'] != 'PBKDF2-HMAC-SHA256') {
      throw const BackupException(
        'This encrypted backup uses a method this app does not support.',
        BackupErrorCode.unsupportedFormat,
      );
    }
    final Object? iterations = header['kdf_iterations'];
    if (iterations is! int ||
        iterations < kMinReadIterations ||
        iterations > kMaxReadIterations) {
      throw damaged;
    }
    final List<int> salt;
    final List<int> nonce;
    try {
      salt = base64Decode(header['salt']! as String);
      nonce = base64Decode(header['nonce']! as String);
    } on Object {
      throw damaged;
    }
    if (salt.length < 8 || salt.length > 64 || nonce.length != _nonceLength) {
      throw damaged;
    }
    return _ParsedEnvelope(
      prefix: Uint8List.sublistView(data, 0, headerEnd),
      salt: salt,
      nonce: nonce,
      iterations: iterations,
      cipherText: data.sublist(headerEnd, data.length - _tagLength),
      tag: data.sublist(data.length - _tagLength),
      appVersion: header['app_version'] is String ? header['app_version']! as String : '',
      createdAt: parseIsoTime(header['created_at']),
    );
  }
}

class _ParsedEnvelope {
  const _ParsedEnvelope({
    required this.prefix,
    required this.salt,
    required this.nonce,
    required this.iterations,
    required this.cipherText,
    required this.tag,
    required this.appVersion,
    required this.createdAt,
  });

  final Uint8List prefix;
  final List<int> salt;
  final List<int> nonce;
  final int iterations;
  final Uint8List cipherText;
  final Uint8List tag;
  final String appVersion;
  final DateTime? createdAt;
}

Future<List<int>> _deriveKey(
  String password,
  List<int> salt,
  int iterations,
  bool useIsolate,
) {
  Future<List<int>> run() async {
    final SecretKey key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    return key.extractBytes();
  }

  // PBKDF2 is deliberately slow; keep it off the UI thread in the app.
  if (!useIsolate) return run();
  return Isolate.run<List<int>>(run);
}
