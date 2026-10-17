import 'dart:async';

import 'package:flutter/foundation.dart';

import 'attachment_models.dart';
import 'attachment_picker.dart';
import 'document_processor.dart';

/// Holds the files waiting in the message box. Files are only checked and
/// read on the phone here; nothing is uploaded until the user sends the
/// message.
class AttachmentController extends ChangeNotifier {
  AttachmentController({
    required this.picker,
    DocumentProcessor? processor,
    this.maxAttachments = kMaxAttachments,
  }) : _processor = processor ?? DocumentProcessor();

  final AttachmentPickerGateway picker;
  final DocumentProcessor _processor;
  final int maxAttachments;

  final List<ChatAttachment> _items = <ChatAttachment>[];
  final List<String> _problems = <String>[];
  int _counter = 0;
  int _picking = 0;
  bool _disposed = false;

  List<ChatAttachment> get items => List<ChatAttachment>.unmodifiable(_items);
  List<ChatAttachment> get readyItems =>
      _items.where((ChatAttachment a) => a.isReady).toList();

  /// True while the picker is open or a file is being read.
  bool get isBusy => _picking > 0 || _items.any((ChatAttachment a) => !a.isReady);
  bool get isNotEmpty => _items.isNotEmpty;

  /// Validation problems to show (one line per file).
  List<String> get problems => List<String>.unmodifiable(_problems);

  int get totalExtractedChars => _items.fold<int>(
        0,
        (int sum, ChatAttachment a) => sum + (a.extractedText?.length ?? 0),
      );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void dismissProblems() {
    if (_problems.isEmpty) return;
    _problems.clear();
    _notify();
  }

  void remove(String id) {
    _items.removeWhere((ChatAttachment a) => a.id == id);
    _notify();
  }

  /// Removes everything (after sending, or on "clear").
  void clear() {
    _items.clear();
    _problems.clear();
    _notify();
  }

  /// Opens the system picker for [source] and adds what the user chooses.
  Future<void> addFrom(AttachmentSource source) async {
    final int room = maxAttachments - _items.length;
    if (room <= 0) {
      _problems
        ..clear()
        ..add('You can attach up to $maxAttachments files to one message. Remove one first.');
      _notify();
      return;
    }
    _problems.clear();
    _picking++;
    _notify();
    List<PickedAttachment> picked = <PickedAttachment>[];
    try {
      picked = await picker.pick(source, maxCount: room);
    } on AttachmentException catch (e) {
      _problems.add(e.message);
    } on Object {
      _problems.add('The file picker could not be opened. Please try again.');
    } finally {
      _picking--;
    }
    if (_disposed) return;
    if (picked.length > room) picked = picked.take(room).toList();
    _notify();

    // Placeholders first, so every file shows "Reading…" straight away.
    final List<_Pending> pending = <_Pending>[];
    for (final PickedAttachment p in picked) {
      try {
        DocumentProcessor.checkSize(p.name, p.sizeBytes);
      } on AttachmentException catch (e) {
        _problems.add(e.message);
        continue;
      }
      if (_items.any((ChatAttachment a) => a.name == p.name && a.sizeBytes == p.sizeBytes)) {
        _problems.add('${p.name} is already attached.');
        continue;
      }
      final String id = 'att-${++_counter}';
      _items.add(ChatAttachment(id: id, name: p.name, sizeBytes: p.sizeBytes));
      pending.add(_Pending(id, p));
    }
    _notify();

    for (final _Pending job in pending) {
      await _finish(job);
      if (_disposed) return;
    }
    unawaited(picker.clearTemporaryFiles());
    _notify();
  }

  /// Adds a file whose bytes are already in memory (used by tests and by
  /// callers that have the bytes). Same checks as [addFrom].
  Future<void> addBytes(String name, Uint8List bytes) async {
    if (_items.length >= maxAttachments) {
      _problems
        ..clear()
        ..add('You can attach up to $maxAttachments files to one message. Remove one first.');
      _notify();
      return;
    }
    final PickedAttachment p = PickedAttachment(
      name: name,
      sizeBytes: bytes.length,
      read: () async => bytes,
    );
    try {
      DocumentProcessor.checkSize(p.name, p.sizeBytes);
    } on AttachmentException catch (e) {
      _problems.add(e.message);
      _notify();
      return;
    }
    final String id = 'att-${++_counter}';
    _items.add(ChatAttachment(id: id, name: name, sizeBytes: bytes.length));
    _notify();
    await _finish(_Pending(id, p));
  }

  Future<void> _finish(_Pending job) async {
    try {
      final Uint8List bytes = await job.file.read();
      if (!_items.any((ChatAttachment a) => a.id == job.id)) return; // removed meanwhile
      final ChatAttachment done = await _processor.process(
        id: job.id,
        name: job.file.name,
        bytes: bytes,
      );
      final int index = _items.indexWhere((ChatAttachment a) => a.id == job.id);
      if (_disposed || index < 0) return; // removed while reading
      final int others = totalExtractedChars - (_items[index].extractedText?.length ?? 0);
      if (others + (done.extractedText?.length ?? 0) > kMaxTotalExtractedChars) {
        _items.removeAt(index);
        _problems.add(
          '${job.file.name}: too much text together. All attached files can hold up to $kMaxTotalExtractedChars characters. Remove a file or attach a shorter one.',
        );
      } else {
        _items[index] = done;
      }
    } on AttachmentException catch (e) {
      _items.removeWhere((ChatAttachment a) => a.id == job.id);
      _problems.add(e.message);
    } on Object {
      _items.removeWhere((ChatAttachment a) => a.id == job.id);
      _problems.add('${job.file.name}: the file could not be read.');
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Pending {
  const _Pending(this.id, this.file);

  final String id;
  final PickedAttachment file;
}
