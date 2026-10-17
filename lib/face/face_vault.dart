import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'face_matcher.dart';
import 'face_models.dart';

/// Where the encrypted file lives.
abstract class VaultFile {
  Future<Uint8List?> read();
  Future<void> write(Uint8List bytes);
  Future<void> delete();
  Future<bool> exists();
}

class MemoryVaultFile implements VaultFile {
  Uint8List? bytes;

  @override
  Future<Uint8List?> read() async => bytes;

  @override
  Future<void> write(Uint8List data) async => bytes = Uint8List.fromList(data);

  @override
  Future<void> delete() async => bytes = null;

  @override
  Future<bool> exists() async => bytes != null;
}

/// A file in the app-private directory. Writes go to a temporary file first
/// and are renamed, so a crash never leaves a half-written vault.
class IoVaultFile implements VaultFile {
  IoVaultFile(this.path);

  final String path;

  @override
  Future<Uint8List?> read() async {
    final File f = File(path);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> write(Uint8List data) async {
    final File tmp = File('$path.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(path);
  }

  @override
  Future<void> delete() async {
    final File f = File(path);
    if (await f.exists()) await f.delete();
    final File tmp = File('$path.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  @override
  Future<bool> exists() => File(path).exists();
}

/// Holds the 256-bit key that encrypts the vault. In the app it lives in the
/// Android Keystore-backed secure storage, never next to the vault file.
abstract class VaultKeyStore {
  Future<List<int>?> read();
  Future<List<int>> readOrCreate();
  Future<void> delete();
}

class MemoryVaultKeyStore implements VaultKeyStore {
  MemoryVaultKeyStore({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  List<int>? key;

  @override
  Future<List<int>?> read() async => key;

  @override
  Future<List<int>> readOrCreate() async =>
      key ??= List<int>.generate(32, (_) => _random.nextInt(256));

  @override
  Future<void> delete() async => key = null;
}

class SecureStorageVaultKeyStore implements VaultKeyStore {
  SecureStorageVaultKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _name = 'almus_face_vault_key_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<List<int>?> read() async {
    final String? text = await _storage.read(key: _name);
    if (text == null) return null;
    try {
      final List<int> bytes = base64Decode(text);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<int>> readOrCreate() async {
    final List<int>? existing = await read();
    if (existing != null) return existing;
    final Random r = Random.secure();
    final List<int> fresh = List<int>.generate(32, (_) => r.nextInt(256));
    await _storage.write(key: _name, value: base64Encode(fresh));
    return fresh;
  }

  @override
  Future<void> delete() => _storage.delete(key: _name);
}

class VaultContents {
  const VaultContents({
    required this.modelId,
    required this.identities,
    this.unreadable = false,
  });

  const VaultContents.empty()
      : modelId = null,
        identities = const <EnrolledIdentity>[],
        unreadable = false;

  const VaultContents.unreadable()
      : modelId = null,
        identities = const <EnrolledIdentity>[],
        unreadable = true;

  final String? modelId;
  final List<EnrolledIdentity> identities;

  /// True when a vault file exists but cannot be decrypted or parsed. Its
  /// content is lost; the user can delete it and enrol again.
  final bool unreadable;
}

const List<int> _magic = <int>[0x41, 0x46, 0x56, 0x31]; // AFV1
const int _nonceLength = 12;
const int _tagLength = 16;

/// Encrypted storage for face templates (embeddings only, never pictures).
///
/// AES-256-GCM, random nonce per write, the file signature is authenticated.
/// The key is held in [VaultKeyStore]. Deleting the vault removes the file
/// AND the key, so even a surviving copy of the file cannot be decrypted.
class FaceTemplateVault {
  FaceTemplateVault({
    required this.file,
    required this.keys,
    Random? random,
  }) : _random = random ?? Random.secure();

  final VaultFile file;
  final VaultKeyStore keys;
  final Random _random;

  Future<VaultContents> load() async {
    final Uint8List? data = await file.read();
    if (data == null) return const VaultContents.empty();
    try {
      if (data.length < _magic.length + _nonceLength + _tagLength) {
        return const VaultContents.unreadable();
      }
      for (int i = 0; i < _magic.length; i++) {
        if (data[i] != _magic[i]) return const VaultContents.unreadable();
      }
      final List<int>? key = await keys.read();
      if (key == null) return const VaultContents.unreadable();
      final int nonceEnd = _magic.length + _nonceLength;
      final List<int> clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          data.sublist(nonceEnd, data.length - _tagLength),
          nonce: data.sublist(_magic.length, nonceEnd),
          mac: Mac(data.sublist(data.length - _tagLength)),
        ),
        secretKey: SecretKey(key),
        aad: _magic,
      );
      return _decode(utf8.decode(clear));
    } on SecretBoxAuthenticationError {
      return const VaultContents.unreadable();
    } on FormatException {
      return const VaultContents.unreadable();
    } on ArgumentError {
      return const VaultContents.unreadable();
    }
  }

  Future<void> save(String modelId, List<EnrolledIdentity> identities) async {
    final List<int> key = await keys.readOrCreate();
    final List<int> nonce =
        List<int>.generate(_nonceLength, (_) => _random.nextInt(256));
    final List<int> clear = utf8.encode(_encode(modelId, identities));
    final SecretBox box = await AesGcm.with256bits().encrypt(
      clear,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: _magic,
    );
    final BytesBuilder out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    await file.write(out.toBytes());
  }

  /// Removes the vault file and its key. Returns true only when both are
  /// gone afterwards.
  Future<bool> deleteAll() async {
    Object? error;
    try {
      await file.delete();
    } on Object catch (e) {
      error = e;
    }
    try {
      await keys.delete();
    } on Object catch (e) {
      error ??= e;
    }
    if (error != null) return false;
    return !(await file.exists()) && (await keys.read()) == null;
  }

  static String _encode(String modelId, List<EnrolledIdentity> ids) {
    return jsonEncode(<String, Object?>{
      'v': 1,
      'model_id': modelId,
      'identities': <Object?>[
        for (final EnrolledIdentity id in ids)
          <String, Object?>{
            'id': id.id,
            'name': id.displayName,
            'created': id.createdAt.toUtc().toIso8601String(),
            'samples': <String>[
              for (final FaceEmbedding s in id.samples)
                base64Encode(
                  s.values.buffer
                      .asUint8List(s.values.offsetInBytes, s.values.lengthInBytes),
                ),
            ],
          },
      ],
    });
  }

  static VaultContents _decode(String text) {
    final Object? root = jsonDecode(text);
    if (root is! Map<String, Object?> || root['v'] != 1) {
      return const VaultContents.unreadable();
    }
    final Object? modelId = root['model_id'];
    final Object? list = root['identities'];
    if (modelId is! String || list is! List<Object?>) {
      return const VaultContents.unreadable();
    }
    final List<EnrolledIdentity> out = <EnrolledIdentity>[];
    for (final Object? item in list) {
      if (item is! Map<String, Object?>) return const VaultContents.unreadable();
      final Object? id = item['id'];
      final Object? name = item['name'];
      final Object? created = item['created'];
      final Object? samples = item['samples'];
      if (id is! String ||
          name is! String ||
          created is! String ||
          samples is! List<Object?>) {
        return const VaultContents.unreadable();
      }
      final List<FaceEmbedding> embeddings = <FaceEmbedding>[];
      for (final Object? s in samples) {
        if (s is! String) return const VaultContents.unreadable();
        final Uint8List bytes = base64Decode(s);
        if (bytes.isEmpty || bytes.length % 4 != 0) {
          return const VaultContents.unreadable();
        }
        final Float32List floats = Float32List.fromList(
          Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4),
        );
        embeddings.add(FaceEmbedding.fromStored(floats, modelId));
      }
      out.add(EnrolledIdentity(
        id: id,
        displayName: name,
        createdAt: DateTime.parse(created),
        samples: embeddings,
      ));
    }
    return VaultContents(modelId: modelId, identities: out);
  }
}
