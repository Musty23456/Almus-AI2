import 'dart:convert';
import 'dart:typed_data';

import 'package:almus_ai/backup/backup_codec.dart';
import 'package:almus_ai/backup/backup_crypto.dart';
import 'package:almus_ai/backup/backup_models.dart';
import 'package:almus_ai/backup/import_adapters.dart';
import 'package:almus_ai/backup/transcript_formats.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backup_fakes.dart';

const BackupCodec codec = BackupCodec();
final DateTime now = DateTime.utc(2026, 2, 3, 4, 5, 6);

Uint8List zipOf(BackupBundle b) => codec.encodeZip(
      b,
      appName: 'ALMUS AI',
      appVersion: '0.10.0',
      appBuild: '10',
      now: now,
    );

BackupException? thrown(void Function() f) {
  try {
    f();
  } on BackupException catch (e) {
    return e;
  }
  return null;
}

ImportService importer() => ImportService(
      crypto: BackupCrypto.forTesting(iterations: 1000),
      clock: () => now,
    );

void main() {
  const String hausa = 'Sannu! Ɓarna, ɗan ƙasa, ƴar uwa, Ƙanƙara — 你好 🌍';

  group('ZIP backup format', () {
    test('empty backup round-trips', () {
      final BackupBundle out = codec.decodeZip(zipOf(const BackupBundle()));
      expect(out.conversations, isEmpty);
      expect(out.memories, isEmpty);
    });

    test('multiple conversations, empty conversation, Unicode, ordering', () {
      final BackupBundle input = BackupBundle(
        conversations: <BackupConversation>[
          makeConversation('a', text: hausa),
          makeConversation('b', messages: 0),
          makeConversation('c', messages: 5, minute: 10),
        ],
        memories: <BackupMemory>[makeMemory('m1', text: hausa)],
        settings: const BackupSettings(memoryEnabled: false, conversationMemoryOff: <String>['a']),
      );
      final BackupBundle out = codec.decodeZip(zipOf(input));
      expect(out.conversations.map((BackupConversation c) => c.id), <String>['a', 'b', 'c']);
      expect(out.conversations[0].messages.first.content, '$hausa 0');
      expect(out.conversations[1].messages, isEmpty);
      expect(out.conversations[2].messages.map((BackupMessage m) => m.id),
          <String>['c-m0', 'c-m1', 'c-m2', 'c-m3', 'c-m4']);
      expect(out.conversations[0].createdAt, t(0));
      expect(out.memories.single.text, hausa);
      expect(out.settings!.memoryEnabled, false);
      expect(out.settings!.conversationMemoryOff, <String>['a']);
      expect(out.appVersion, '0.10.0');
    });

    test('large backup (20,000 messages) round-trips', () {
      final BackupBundle input = BackupBundle(
        conversations: <BackupConversation>[
          for (int i = 0; i < 100; i++) makeConversation('c$i', messages: 200),
        ],
      );
      final BackupBundle out = codec.decodeZip(zipOf(input));
      expect(out.conversations.length, 100);
      expect(out.messageCount, 20000);
    });

    test('corrupted archive is rejected with a clear message', () {
      final Uint8List good = zipOf(BackupBundle(conversations: <BackupConversation>[makeConversation('a')]));
      final Uint8List bad = Uint8List.fromList(good.sublist(0, good.length ~/ 2));
      final BackupException? e = thrown(() => codec.decodeZip(bad));
      expect(e, isNotNull);
      expect(e!.code, BackupErrorCode.corrupted);
    });

    test('tampered data fails the checksum', () {
      final Archive archive = ZipDecoder().decodeBytes(
        zipOf(BackupBundle(conversations: <BackupConversation>[makeConversation('a')])),
      );
      final Archive changed = Archive();
      for (final ArchiveFile f in archive.files) {
        List<int> data = f.content as List<int>;
        if (f.name == kConversationsPath) {
          data = utf8.encode(utf8.decode(data).replaceAll('Hello', 'Hullo'));
        }
        changed.addFile(ArchiveFile(f.name, data.length, data));
      }
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(changed)!);
      final BackupException? e = thrown(() => codec.decodeZip(bytes));
      expect(e!.code, BackupErrorCode.corrupted);
      expect(e.message, contains('checksum'));
    });

    test('unsupported schema version is refused', () {
      final Archive archive = ZipDecoder().decodeBytes(zipOf(const BackupBundle()));
      final Archive changed = Archive();
      for (final ArchiveFile f in archive.files) {
        List<int> data = f.content as List<int>;
        if (f.name == kManifestPath) {
          final Map<String, Object?> m = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
          m['schema_version'] = 99;
          data = utf8.encode(jsonEncode(m));
        }
        changed.addFile(ArchiveFile(f.name, data.length, data));
      }
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(changed)!);
      expect(thrown(() => codec.decodeZip(bytes))!.code, BackupErrorCode.unsupportedVersion);
    });

    test('a ZIP without a manifest is not an ALMUS backup', () {
      final Archive a = Archive()..addFile(ArchiveFile('x.txt', 1, <int>[65]));
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(a)!);
      expect(thrown(() => codec.decodeZip(bytes))!.code, BackupErrorCode.unsupportedFormat);
    });

    test('backup never contains credentials', () {
      final Archive archive = ZipDecoder().decodeBytes(
        zipOf(BackupBundle(conversations: <BackupConversation>[makeConversation('a')])),
      );
      final String all = archive.files
          .map((ArchiveFile f) => utf8.decode(f.content as List<int>))
          .join()
          .toLowerCase();
      for (final String word in <String>['access_token', 'backend_url', 'api_key', 'password']) {
        expect(all.contains(word), isFalse, reason: word);
      }
    });
  });

  group('encryption', () {
    test('round-trip, header holds parameters, no plaintext leaks', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List plain = zipOf(BackupBundle(conversations: <BackupConversation>[makeConversation('a', text: hausa)]));
      final Uint8List enc = await crypto.encrypt(plain, 'correct horse', appVersion: '0.10.0', now: now);
      expect(BackupCrypto.looksEncrypted(enc), isTrue);
      expect(BackupCrypto.readInfo(enc)!.iterations, 1000);
      expect(latin1.decode(enc).contains(hausa), isFalse);
      expect(latin1.decode(enc).contains('correct horse'), isFalse);
      expect(await crypto.decrypt(enc, 'correct horse'), plain);
    });

    test('same input encrypts differently each time (random salt/nonce)', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List plain = Uint8List.fromList(<int>[1, 2, 3]);
      final Uint8List a = await crypto.encrypt(plain, 'password1', appVersion: '1', now: now);
      final Uint8List b = await crypto.encrypt(plain, 'password1', appVersion: '1', now: now);
      expect(a, isNot(b));
    });

    test('wrong password is rejected safely', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List enc = await crypto.encrypt(Uint8List.fromList(<int>[9]), 'password1', appVersion: '1', now: now);
      await expectLater(
        crypto.decrypt(enc, 'password2'),
        throwsA(isA<BackupException>().having((BackupException e) => e.code, 'code', BackupErrorCode.wrongPassword)),
      );
    });

    test('flipped ciphertext byte and edited header are rejected', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List enc = await crypto.encrypt(Uint8List.fromList(List<int>.filled(100, 7)), 'password1', appVersion: '1', now: now);
      final Uint8List flipped = Uint8List.fromList(enc)..[enc.length - 20] ^= 1;
      await expectLater(crypto.decrypt(flipped, 'password1'), throwsA(isA<BackupException>()));
      // Change one header character (the app version) - the header is authenticated.
      final String text = latin1.decode(enc);
      final int at = text.indexOf('"app_version":"1"') + 15;
      final Uint8List edited = Uint8List.fromList(enc)..[at] = '2'.codeUnitAt(0);
      await expectLater(crypto.decrypt(edited, 'password1'), throwsA(isA<BackupException>()));
    });

    test('truncated file is reported as damaged', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List enc = await crypto.encrypt(Uint8List.fromList(<int>[1]), 'password1', appVersion: '1', now: now);
      await expectLater(crypto.decrypt(enc.sublist(0, 30), 'password1'), throwsA(isA<BackupException>()));
    });

    test('short passwords and low work factors are refused when creating', () async {
      await expectLater(
        BackupCrypto.forTesting(iterations: 1000).encrypt(Uint8List(1), 'short', appVersion: '1', now: now),
        throwsA(isA<BackupException>()),
      );
      expect(BackupCrypto.passwordProblem('12345678'), isNull);
    });

    test('production crypto uses the documented work factor and the isolate path works', () async {
      final BackupCrypto crypto = BackupCrypto();
      expect(crypto.iterations, kDefaultKdfIterations);
      final BackupCrypto fast = BackupCrypto.forTesting(iterations: 1000, useIsolate: true);
      final Uint8List enc = await fast.encrypt(Uint8List.fromList(<int>[5, 6]), 'password1', appVersion: '1', now: now);
      expect(await fast.decrypt(enc, 'password1'), <int>[5, 6]);
    });

    test('import service asks for a password, then decrypts', () async {
      final BackupCrypto crypto = BackupCrypto.forTesting(iterations: 1000);
      final Uint8List zip = zipOf(BackupBundle(conversations: <BackupConversation>[makeConversation('a')]));
      final Uint8List enc = await crypto.encrypt(zip, 'password1', appVersion: '1', now: now);
      await expectLater(
        importer().inspect(enc),
        throwsA(isA<BackupException>().having((BackupException e) => e.code, 'code', BackupErrorCode.passwordRequired)),
      );
      final ParsedImport p = await importer().inspect(enc, password: 'password1');
      expect(p.encrypted, isTrue);
      expect(p.bundle.conversations.single.id, 'a');
    });
  });

  group('transcripts', () {
    final List<BackupConversation> sample = <BackupConversation>[
      makeConversation('a', title: 'Hausa $hausa', text: hausa),
      BackupConversation(
        id: 'multi',
        title: 'Multi line',
        createdAt: t(0),
        updatedAt: t(1),
        messages: <BackupMessage>[
          BackupMessage(id: 'x1', conversationId: 'multi', role: 'user', content: 'line1\n\n    indented\nlast', createdAt: t(0)),
          BackupMessage(id: 'x2', conversationId: 'multi', role: 'assistant', content: 'ok', createdAt: t(0), engine: 'GEMINI', status: 'error'),
        ],
      ),
      makeConversation('empty', messages: 0),
    ];

    void expectSame(List<BackupConversation> out) {
      expect(out.map((BackupConversation c) => c.id), <String>['a', 'multi', 'empty']);
      expect(out[0].title, sample[0].title);
      expect(out[0].messages.first.content, '$hausa 0');
      expect(out[1].messages[0].content, 'line1\n\n    indented\nlast');
      expect(out[1].messages[1].engine, 'GEMINI');
      expect(out[1].messages[1].status, 'error');
      expect(out[1].messages[0].createdAt, t(0));
      expect(out[2].messages, isEmpty);
    }

    test('JSON round-trip', () async {
      final String text = conversationsToJson(sample, appVersion: '0.10.0', exportedAt: now);
      final ParsedImport p = await importer().inspect(Uint8List.fromList(utf8.encode(text)));
      expect(p.source, ImportSource.almusJson);
      expectSame(p.bundle.conversations);
    });

    test('TXT round-trip', () async {
      final String text = conversationsToTxt(sample, appVersion: '0.10.0', exportedAt: now);
      expect(text, contains(hausa));
      final ParsedImport p = await importer().inspect(Uint8List.fromList(utf8.encode(text)));
      expect(p.source, ImportSource.almusTxt);
      expectSame(p.bundle.conversations);
    });

    test('Markdown round-trip', () async {
      final String text = conversationsToMarkdown(sample, appVersion: '0.10.0', exportedAt: now);
      expect(text, contains(hausa));
      final ParsedImport p = await importer().inspect(Uint8List.fromList(utf8.encode(text)));
      expect(p.source, ImportSource.almusMarkdown);
      expectSame(p.bundle.conversations);
    });

    test('memory export keeps fields and Unicode', () {
      final String json = memoriesToJson(<BackupMemory>[makeMemory('m1', text: hausa)], appVersion: '1', exportedAt: now);
      final BackupBundle b = BackupBundle.fromExportJson(jsonDecode(json) as Map<String, Object?>);
      expect(b.memories.single.text, hausa);
      expect(b.memories.single.status, 'confirmed');
      expect(memoriesToMarkdown(<BackupMemory>[makeMemory('m1', text: hausa)], appVersion: '1', exportedAt: now), contains(hausa));
    });
  });

  group('import adapters', () {
    Future<ParsedImport> read(String text, {String name = 'chat.txt'}) =>
        importer().inspect(Uint8List.fromList(utf8.encode(text)), fileName: name);

    test('invalid JSON gives a clear error', () async {
      await expectLater(read('{"conversations": [', name: 'x.json'), throwsA(isA<BackupException>().having((BackupException e) => e.message, 'message', contains('not valid JSON'))));
    });

    test('generic JSON: documented shape, Unicode, epoch and ISO times, system skipped', () async {
      final ParsedImport p = await read(jsonEncode(<String, Object?>{
        'conversations': <Object?>[
          <String, Object?>{
            'title': 'Gwaji',
            'messages': <Object?>[
              <String, Object?>{'role': 'system', 'content': 'ignore'},
              <String, Object?>{'role': 'user', 'content': hausa, 'timestamp': 1767261600},
              <String, Object?>{'role': 'assistant', 'text': 'Na gode', 'created_at': '2026-01-01T10:01:00Z'},
              <String, Object?>{'role': 'tool', 'content': 'x'},
            ],
          },
        ],
      }));
      expect(p.source, ImportSource.genericJson);
      final BackupConversation c = p.bundle.conversations.single;
      expect(c.messages.length, 2);
      expect(c.messages.first.content, hausa);
      expect(c.messages.first.createdAt, DateTime.fromMillisecondsSinceEpoch(1767261600000, isUtc: true));
      expect(p.bundle.warnings, isNotEmpty);
    });

    test('generic JSON ids are stable, so a repeat import finds the same ids', () async {
      const String doc = '[{"role":"user","content":"a"},{"role":"assistant","content":"b"}]';
      final ParsedImport one = await read(doc, name: 'x.json');
      final ParsedImport two = await read(doc, name: 'x.json');
      expect(one.bundle.conversations.single.id, two.bundle.conversations.single.id);
    });

    test('JSON with no usable messages and unknown formats are explained', () async {
      await expectLater(read('{"conversations":[{"messages":[{"role":"tool","content":"x"}]}]}'), throwsA(isA<BackupException>()));
      await expectLater(read('{"foo": 1}'), throwsA(isA<BackupException>()));
      await expectLater(read('{"format":"other-app","conversations":[]}'), throwsA(isA<BackupException>()));
    });

    test('plain "You:/Assistant:" transcript', () async {
      final ParsedImport p = await read('Intro line\nYou: Sannu\nAssistant: Barka\nda zuwa\n', name: 'my_chat.txt');
      expect(p.source, ImportSource.plainTranscript);
      final BackupConversation c = p.bundle.conversations.single;
      expect(c.title, 'my chat');
      expect(c.messages[1].content, 'Barka\nda zuwa');
    });

    test('unrecognised text and binary files are rejected', () async {
      await expectLater(read('just some words with no speakers'), throwsA(isA<BackupException>()));
      await expectLater(importer().inspect(Uint8List.fromList(<int>[0, 1, 2, 3])), throwsA(isA<BackupException>()));
      await expectLater(importer().inspect(Uint8List(0)), throwsA(isA<BackupException>()));
    });

    test('duplicate ids inside one file are refused', () async {
      final String text = conversationsToJson(<BackupConversation>[makeConversation('a'), makeConversation('a')], appVersion: '1', exportedAt: now);
      await expectLater(read(text, name: 'x.json'), throwsA(isA<BackupException>()));
    });

    test('newer export schema is refused', () async {
      final String text = conversationsToJson(<BackupConversation>[makeConversation('a')], appVersion: '1', exportedAt: now)
          .replaceFirst('"schema_version": 1', '"schema_version": 7');
      await expectLater(read(text, name: 'x.json'), throwsA(isA<BackupException>().having((BackupException e) => e.code, 'code', BackupErrorCode.unsupportedVersion)));
    });
  });
}
