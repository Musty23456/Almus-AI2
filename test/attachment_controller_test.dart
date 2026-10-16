import 'dart:async';
import 'dart:typed_data';

import 'package:almus_ai/attachments/attachment_controller.dart';
import 'package:almus_ai/attachments/attachment_models.dart';
import 'package:almus_ai/attachments/attachment_picker.dart';
import 'package:almus_ai/attachments/document_processor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_fixtures.dart';

class FakePicker implements AttachmentPickerGateway {
  List<PickedAttachment> next = <PickedAttachment>[];
  AttachmentException? error;
  Completer<void>? gate;
  final List<AttachmentSource> asked = <AttachmentSource>[];
  int cleaned = 0;
  int? lastMax;

  @override
  Future<List<PickedAttachment>> pick(AttachmentSource source, {required int maxCount}) async {
    asked.add(source);
    lastMax = maxCount;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return next;
  }

  @override
  Future<void> clearTemporaryFiles() async => cleaned++;
}

PickedAttachment pick(String name, Uint8List bytes, {int? size}) =>
    PickedAttachment(name: name, sizeBytes: size ?? bytes.length, read: () async => bytes);

AttachmentController make(FakePicker p, {int max = 5}) =>
    AttachmentController(picker: p, processor: DocumentProcessor(useIsolate: false), maxAttachments: max);

void main() {
  test('adds a text file and a PNG: ready, with preview data and sizes', () async {
    final FakePicker p = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('hello')), pick('p.png', pngBytes())];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.document);
    expect(c.items.length, 2);
    expect(c.items.every((ChatAttachment a) => a.isReady), isTrue);
    expect(c.items[1].thumbnail, isNotNull);
    expect(c.problems, isEmpty);
    expect(c.isBusy, isFalse);
    expect(p.cleaned, 1, reason: 'temporary picker copies are cleaned up');
    c.dispose();
  });

  test('shows "reading" while a file is processed and busy while the picker is open', () async {
    final FakePicker p = FakePicker()..gate = Completer<void>();
    final AttachmentController c = make(p);
    final Future<void> f = c.addFrom(AttachmentSource.image);
    await Future<void>.delayed(Duration.zero);
    expect(c.isBusy, isTrue);
    p.next = <PickedAttachment>[pick('a.txt', utf8Bytes('x'))];
    p.gate!.complete();
    await f;
    expect(c.isBusy, isFalse);
    c.dispose();
  });

  test('picker cancelled: nothing added, no error', () async {
    final AttachmentController c = make(FakePicker());
    await c.addFrom(AttachmentSource.pdf);
    expect(c.items, isEmpty);
    expect(c.problems, isEmpty);
    c.dispose();
  });

  test('permission denied / picker failure becomes a visible problem', () async {
    final FakePicker p = FakePicker()..error = const AttachmentException('Camera permission was not granted.');
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.camera);
    expect(c.problems.single, contains('Camera permission'));
    expect(c.isBusy, isFalse);
    c.dispose();
  });

  test('unsupported, oversized, empty, renamed and corrupted files each get a clear message; good ones still attach', () async {
    final FakePicker p = FakePicker()
      ..next = <PickedAttachment>[
        pick('virus.exe', utf8Bytes('x')),
        pick('huge.pdf', Uint8List(10), size: kMaxDocumentBytes + 5),
        pick('empty.txt', Uint8List(0)),
        pick('fake.pdf', docxOf(<String>['a'])),
        pick('cut.png', truncatedPng()),
        pick('good.txt', utf8Bytes('fine')),
      ];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.document);
    expect(c.items.map((ChatAttachment a) => a.name), <String>['good.txt']);
    expect(c.problems.length, 5);
    expect(c.problems.join('\n'), contains('exe'));
    expect(c.problems.join('\n'), contains('limit'));
    expect(c.problems.join('\n'), contains('empty'));
    expect(c.problems.join('\n'), contains('Word document'));
    expect(c.problems.join('\n'), contains('damaged'));
    c.dismissProblems();
    expect(c.problems, isEmpty);
    c.dispose();
  });

  test('a failed read leaves no half-added file', () async {
    final FakePicker p = FakePicker()
      ..next = <PickedAttachment>[
        PickedAttachment(name: 'a.txt', sizeBytes: 5, read: () async => throw StateError('io')),
      ];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.text);
    expect(c.items, isEmpty);
    expect(c.problems.single, contains('a.txt'));
    c.dispose();
  });

  test('limit of files per message, and the picker is told how many fit', () async {
    final FakePicker p = FakePicker();
    final AttachmentController c = make(p, max: 2);
    p.next = <PickedAttachment>[pick('a.txt', utf8Bytes('a')), pick('b.txt', utf8Bytes('b')), pick('c.txt', utf8Bytes('c'))];
    await c.addFrom(AttachmentSource.document);
    expect(p.lastMax, 2);
    expect(c.items.length, 2);
    await c.addFrom(AttachmentSource.document);
    expect(c.problems.single, contains('up to 2'));
    c.dispose();
  });

  test('the same file twice is not attached twice', () async {
    final FakePicker p = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('a'))];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.text);
    await c.addFrom(AttachmentSource.text);
    expect(c.items.length, 1);
    expect(c.problems.single, contains('already attached'));
    c.dispose();
  });

  test('attachment removal, then clear', () async {
    final FakePicker p = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('a')), pick('b.txt', utf8Bytes('b'))];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.text);
    c.remove(c.items.first.id);
    expect(c.items.map((ChatAttachment a) => a.name), <String>['b.txt']);
    c.clear();
    expect(c.items, isEmpty);
    c.dispose();
  });

  test('removing a file while it is being read: it does not come back', () async {
    final Completer<Uint8List> slow = Completer<Uint8List>();
    final FakePicker p = FakePicker()
      ..next = <PickedAttachment>[PickedAttachment(name: 'a.txt', sizeBytes: 3, read: () => slow.future)];
    final AttachmentController c = make(p);
    final Future<void> f = c.addFrom(AttachmentSource.text);
    await Future<void>.delayed(Duration.zero);
    expect(c.items.single.isReady, isFalse);
    c.remove(c.items.single.id);
    slow.complete(utf8Bytes('abc'));
    await f;
    expect(c.items, isEmpty);
    c.dispose();
  });

  test('app lifecycle: the controller can be disposed while a file is still being read', () async {
    final Completer<Uint8List> slow = Completer<Uint8List>();
    final FakePicker p = FakePicker()
      ..next = <PickedAttachment>[PickedAttachment(name: 'a.txt', sizeBytes: 3, read: () => slow.future)];
    final AttachmentController c = make(p);
    final Future<void> f = c.addFrom(AttachmentSource.text);
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    slow.complete(utf8Bytes('abc'));
    await f; // must not throw "used after dispose"
  });

  test('files stay in the box across screen changes (state lives in the controller)', () async {
    final FakePicker p = FakePicker()..next = <PickedAttachment>[pick('a.txt', utf8Bytes('a'))];
    final AttachmentController c = make(p, max: 6);
    await c.addFrom(AttachmentSource.text);
    final List<ChatAttachment> before = c.items;
    expect(c.items, before);
    expect(c.readyItems.length, 1);
    c.dispose();
  });

  test('too much text in total is refused for the file that goes over', () async {
    final String big = List<String>.generate(2500, (int i) => 'line $i of the document').join('\n');
    final FakePicker p = FakePicker()
      ..next = <PickedAttachment>[pick('a.txt', utf8Bytes(big)), pick('b.txt', utf8Bytes(big)), pick('c.txt', utf8Bytes(big))];
    final AttachmentController c = make(p);
    await c.addFrom(AttachmentSource.text);
    expect(c.items.length, 2);
    expect(c.problems.single, contains('too much text'));
    expect(c.totalExtractedChars, lessThanOrEqualTo(kMaxTotalExtractedChars));
    c.dispose();
  });

  test('addBytes applies the same checks', () async {
    final AttachmentController c = make(FakePicker());
    await c.addBytes('fake.pdf', utf8Bytes('hello'));
    expect(c.items, isEmpty);
    expect(c.problems, isNotEmpty);
    await c.addBytes('ok.csv', utf8Bytes('a,b\n1,2'));
    expect(c.items.single.kind, AttachmentKind.csv);
    c.dispose();
  });
}
