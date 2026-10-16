import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

import 'attachment_models.dart';

/// What the user asked to choose in the attachment sheet.
enum AttachmentSource {
  image('Choose image'),
  camera('Take photo'),
  document('Choose document'),
  pdf('Choose PDF'),
  text('Choose text file'),
  spreadsheet('Choose CSV or spreadsheet');

  const AttachmentSource(this.label);

  final String label;
}

/// One file handed over by a system picker. The bytes are read only when
/// [read] is called, after the size has been checked, so a huge file is
/// never loaded just to be refused.
class PickedAttachment {
  const PickedAttachment({
    required this.name,
    required this.sizeBytes,
    required this.read,
  });

  final String name;
  final int sizeBytes;
  final Future<Uint8List> Function() read;
}

/// Opens the Android system pickers. Content URIs are handled by the
/// plugins (they copy the chosen file to a temporary cache file); the app
/// never builds or stores a device path.
abstract class AttachmentPickerGateway {
  /// Returns an empty list when the user cancels. Throws
  /// [AttachmentException] with a helpful message when a picker is not
  /// available or a permission was refused.
  Future<List<PickedAttachment>> pick(AttachmentSource source, {required int maxCount});

  /// Deletes the temporary copies made by the pickers (best effort).
  Future<void> clearTemporaryFiles();
}

class SystemAttachmentPicker implements AttachmentPickerGateway {
  SystemAttachmentPicker({ImagePicker? imagePicker}) : _images = imagePicker ?? ImagePicker();

  final ImagePicker _images;

  @override
  Future<List<PickedAttachment>> pick(
    AttachmentSource source, {
    required int maxCount,
  }) async {
    try {
      switch (source) {
        case AttachmentSource.image:
          final List<XFile> files = await _images.pickMultiImage();
          return <PickedAttachment>[
            for (final XFile f in files.take(maxCount)) await _fromXFile(f),
          ];
        case AttachmentSource.camera:
          final XFile? shot = await _images.pickImage(
            source: ImageSource.camera,
            imageQuality: 85,
            maxWidth: 2048,
            maxHeight: 2048,
          );
          return shot == null ? <PickedAttachment>[] : <PickedAttachment>[await _fromXFile(shot)];
        case AttachmentSource.pdf:
          return await _files(maxCount, const <String>['pdf']);
        case AttachmentSource.spreadsheet:
          return await _files(maxCount, const <String>['csv', 'tsv', 'xlsx']);
        case AttachmentSource.document:
        case AttachmentSource.text:
          // Any type is offered: some phones do not know the MIME types of
          // .md or .log files, and every pick is checked afterwards anyway.
          return await _files(maxCount, null);
      }
    } on PlatformException catch (e) {
      throw AttachmentException(_platformMessage(source, e));
    }
  }

  Future<PickedAttachment> _fromXFile(XFile f) async {
    return PickedAttachment(
      name: f.name,
      sizeBytes: await f.length(),
      read: f.readAsBytes,
    );
  }

  Future<List<PickedAttachment>> _files(int maxCount, List<String>? extensions) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
      allowMultiple: maxCount > 1,
      withData: false,
    );
    if (result == null) return <PickedAttachment>[];
    return <PickedAttachment>[
      for (final PlatformFile f in result.files.take(maxCount))
        PickedAttachment(
          name: f.name,
          sizeBytes: f.size,
          read: () async {
            final Uint8List? inMemory = f.bytes;
            if (inMemory != null) return inMemory;
            final String? path = f.path;
            if (path == null) {
              throw const AttachmentException(
                'Android did not give the app access to that file. Try choosing it again.',
              );
            }
            return File(path).readAsBytes();
          },
        ),
    ];
  }

  String _platformMessage(AttachmentSource source, PlatformException e) {
    final String code = e.code.toLowerCase();
    if (code.contains('camera_access_denied') || code.contains('permission')) {
      return source == AttachmentSource.camera
          ? 'Camera permission was not granted. Allow Camera for ALMUS AI in Android Settings > Apps > ALMUS AI > Permissions, or choose an existing image instead.'
          : 'Android refused access to your files. Try again, or allow access when asked.';
    }
    if (source == AttachmentSource.camera) {
      return 'No camera is available on this device, or the camera app could not be opened. Choose an existing image instead.';
    }
    return 'The file picker could not be opened. Please try again.';
  }

  @override
  Future<void> clearTemporaryFiles() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } on Object {
      // Best effort.
    }
  }
}
