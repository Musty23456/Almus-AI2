import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashing;

import 'backup_models.dart';

const String kManifestPath = 'manifest.json';
const String kConversationsPath = 'data/conversations.json';
const String kMemoriesPath = 'data/memories.json';
const String kSettingsPath = 'data/settings.json';

String sha256Hex(List<int> bytes) => hashing.sha256.convert(bytes).toString();

/// Reads and writes the complete-backup ZIP format (see
/// docs/BACKUP_FORMAT.md). Pure Dart: no Flutter, no storage, no network.
class BackupCodec {
  const BackupCodec();

  /// Builds the ZIP bytes for [bundle].
  Uint8List encodeZip(
    BackupBundle bundle, {
    required String appName,
    required String appVersion,
    required String appBuild,
    required DateTime now,
  }) {
    final Map<String, Uint8List> data = <String, Uint8List>{
      kConversationsPath: _json(<String, Object?>{
        'schema_version': kBackupSchemaVersion,
        'conversations': <Object?>[
          for (final BackupConversation c in bundle.conversations) c.toJson(),
        ],
      }),
      kMemoriesPath: _json(<String, Object?>{
        'schema_version': kBackupSchemaVersion,
        'memories': <Object?>[
          for (final BackupMemory m in bundle.memories) m.toJson(),
        ],
      }),
      if (bundle.settings != null)
        kSettingsPath: _json(<String, Object?>{
          'schema_version': kBackupSchemaVersion,
          ...bundle.settings!.toJson(),
        }),
    };

    final Map<String, Object?> manifest = <String, Object?>{
      'format': kBackupFormatId,
      'schema_version': kBackupSchemaVersion,
      'app': <String, Object?>{
        'name': appName,
        'version': appVersion,
        'build': appBuild,
      },
      'created_at': isoTime(now),
      'encryption': 'none',
      'contents': <String, Object?>{
        'conversations': bundle.conversations.length,
        'messages': bundle.messageCount,
        'memories': bundle.memories.length,
        'settings': bundle.settings != null,
        'attachments': 0,
      },
      'files': <Object?>[
        for (final MapEntry<String, Uint8List> e in data.entries)
          <String, Object?>{
            'path': e.key,
            'sha256': sha256Hex(e.value),
            'bytes': e.value.length,
          },
      ],
      'notes':
          'Attachments are not supported by this app version. Provider keys, access tokens and app-lock data are never included.',
    };

    final Archive archive = Archive();
    final Uint8List manifestBytes = _json(manifest);
    archive.addFile(ArchiveFile(kManifestPath, manifestBytes.length, manifestBytes));
    for (final MapEntry<String, Uint8List> e in data.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const BackupException(
        'The backup archive could not be created.',
        BackupErrorCode.corrupted,
      );
    }
    return Uint8List.fromList(encoded);
  }

  /// Parses and fully validates ZIP bytes. Nothing is written anywhere.
  BackupBundle decodeZip(Uint8List bytes) {
    if (bytes.length > kMaxInputBytes) {
      throw const BackupException(
        'This file is too large to import.',
        BackupErrorCode.tooLarge,
      );
    }
    final Archive archive = _openArchive(bytes);

    final Map<String, ArchiveFile> entries = <String, ArchiveFile>{};
    int declaredTotal = 0;
    for (final ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      declaredTotal += f.size;
      entries[f.name] = f;
    }
    if (declaredTotal > kMaxUncompressedBytes) {
      throw const BackupException(
        'The archive expands to more data than the app will import.',
        BackupErrorCode.tooLarge,
      );
    }

    final ArchiveFile? manifestFile = entries[kManifestPath];
    if (manifestFile == null) {
      throw const BackupException(
        'This ZIP is not an ALMUS AI backup (manifest.json is missing).',
        BackupErrorCode.unsupportedFormat,
      );
    }
    final Map<String, Object?> manifest =
        asJsonMap(_decodeJson(_content(manifestFile), 'manifest.json'), 'manifest.json');
    if (manifest['format'] != kBackupFormatId) {
      throw const BackupException(
        'This ZIP is not an ALMUS AI backup.',
        BackupErrorCode.unsupportedFormat,
      );
    }
    final Object? version = manifest['schema_version'];
    if (version is! int || version < 1) {
      throw const BackupException(
        'The backup manifest has no valid schema_version.',
        BackupErrorCode.corrupted,
      );
    }
    if (version > kBackupSchemaVersion) {
      throw BackupException(
        'This backup uses format version $version. This app understands up to version $kBackupSchemaVersion. Update ALMUS AI and try again.',
        BackupErrorCode.unsupportedVersion,
      );
    }
    if (manifest['encryption'] != null && manifest['encryption'] != 'none') {
      throw const BackupException(
        'The manifest reports an unsupported encryption setting.',
        BackupErrorCode.unsupportedFormat,
      );
    }

    // Verify every listed file against its checksum before trusting it.
    final Map<String, Uint8List> verified = <String, Uint8List>{};
    final List<Object?> listed = asJsonList(manifest['files'], 'manifest.files');
    for (int i = 0; i < listed.length; i++) {
      final Map<String, Object?> item =
          asJsonMap(listed[i], 'manifest.files[$i]');
      final Object? path = item['path'];
      final Object? expected = item['sha256'];
      if (path is! String || expected is! String) {
        throw const BackupException(
          'The backup manifest has an invalid file list.',
          BackupErrorCode.corrupted,
        );
      }
      final ArchiveFile? file = entries[path];
      if (file == null) {
        throw BackupException(
          'The backup is incomplete: $path is missing.',
          BackupErrorCode.corrupted,
        );
      }
      final Uint8List content = _content(file);
      if (sha256Hex(content) != expected.toLowerCase()) {
        throw BackupException(
          'The backup is damaged: the checksum of $path does not match.',
          BackupErrorCode.corrupted,
        );
      }
      verified[path] = content;
    }

    Object? part(String path, String key) {
      final Uint8List? content = verified[path];
      if (content == null) return null;
      final Map<String, Object?> doc = asJsonMap(_decodeJson(content, path), path);
      final Object? partVersion = doc['schema_version'];
      if (partVersion is int && partVersion > kBackupSchemaVersion) {
        throw BackupException(
          '$path uses an unsupported format version.',
          BackupErrorCode.unsupportedVersion,
        );
      }
      return key.isEmpty ? doc : doc[key];
    }

    final Object? settingsDoc = part(kSettingsPath, '');
    final Map<String, Object?>? settingsMap =
        settingsDoc == null ? null : asJsonMap(settingsDoc, kSettingsPath);

    final Object? app = manifest['app'];
    final BackupBundle bundle = BackupBundle.fromParts(
      conversations: part(kConversationsPath, 'conversations'),
      memories: part(kMemoriesPath, 'memories'),
      settings: settingsMap,
      appVersion: app is Map && app['version'] is String ? app['version'] as String : '',
      schemaVersion: version,
      exportedAt: parseIsoTime(manifest['created_at']),
    );

    // The manifest counts must agree with what was actually read.
    final Object? contents = manifest['contents'];
    if (contents is Map) {
      final bool consistent =
          contents['conversations'] == bundle.conversations.length &&
              contents['messages'] == bundle.messageCount &&
              contents['memories'] == bundle.memories.length;
      if (!consistent) {
        throw const BackupException(
          'The backup is damaged: the record counts in the manifest do not match the data.',
          BackupErrorCode.corrupted,
        );
      }
    }
    return bundle;
  }

  Archive _openArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object {
      throw const BackupException(
        'This ZIP archive is damaged or incomplete and cannot be read.',
        BackupErrorCode.corrupted,
      );
    }
  }

  Uint8List _content(ArchiveFile file) {
    try {
      final Object? raw = file.content;
      if (raw is List<int>) return Uint8List.fromList(raw);
    } on Object {
      // Fall through to the error below.
    }
    throw BackupException(
      'The backup is damaged: ${file.name} could not be unpacked.',
      BackupErrorCode.corrupted,
    );
  }

  Object? _decodeJson(Uint8List bytes, String name) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw BackupException(
        '$name is not valid JSON.',
        BackupErrorCode.corrupted,
      );
    }
  }

  Uint8List _json(Map<String, Object?> value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
