import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

void main() {
  test('extracts each block section with its exact bytes; empty container yields none', () {
    final rsrc = buildRsrc([
      (
        tag: 'vers',
        sections: [
          [1, 2, 3, 4],
          [9, 9],
        ],
      ),
      (
        tag: 'BDHb',
        sections: [
          [0xde, 0xad, 0xbe, 0xef, 0x10],
        ],
      ),
    ]);
    final secs = readViSections(rsrc);
    expect(secs.map((s) => '${s.tag}#${s.index}'), ['vers#0', 'vers#1', 'BDHb#0']);
    expect(secs[0].bytes, [1, 2, 3, 4]);
    expect(secs[1].bytes, [9, 9]);
    expect(secs[2].bytes, [0xde, 0xad, 0xbe, 0xef, 0x10]);
    expect(readViSections(buildRsrc(const [])), isEmpty);
  });

  test('readEmbeddedSections returns LIBN/VINS (word16==0); readViSections excludes them', () {
    final nested = buildRsrc([
      (
        tag: 'vers',
        sections: [
          [9, 9],
        ],
      ),
    ]);
    final rsrc = buildRsrc(
      [
        (
          tag: 'vers',
          sections: [
            [1, 2, 3, 4],
          ],
        ),
        (tag: 'LIBN', sections: ['My.lvlib'.codeUnits]),
        (tag: 'VINS', sections: [nested]),
        (
          tag: 'FTAB',
          sections: [
            [0, 0],
          ],
        ),
      ],
      embeddedTags: {'LIBN', 'VINS'},
    );
    expect(readViSections(rsrc).map((s) => s.tag), ['vers', 'FTAB'], reason: 'primary reader sees only own data');
    final emb = readEmbeddedSections(rsrc);
    expect(emb.map((s) => '${s.tag}#${s.index}'), ['LIBN#0', 'VINS#0']);
    expect(String.fromCharCodes(emb[0].bytes), 'My.lvlib');
    expect(emb[1].bytes.sublist(0, 4), [0x52, 0x53, 0x52, 0x43]);
    expect(String.fromCharCodes(emb[1].bytes.sublist(8, 12)), 'LVIN');
    expect(ViContainer.parse(emb[1].bytes).parsedHeader.fileType, 'LVIN');
  });

  test('readViSections returns bytes as-stored — inflation happens later in videcode', () {
    final payload = [0, 0, 0, 8, 0x78, 0x9c, 1, 2, 3, 4];
    final secs = readViSections(
      buildRsrc([
        (tag: 'BDEx', sections: [payload]),
      ]),
    );
    expect(secs.single.bytes, payload, reason: 'a zlib-looking payload is returned untouched');
  });

  group('inflateSection', () {
    test('inflates a [size][zlib] heap section back to the original bytes', () {
      final payload = List<int>.generate(2000, (i) => (i * 7) % 251);
      final dec = inflateSection(sec('BDEx', compressedSection(payload)));
      expect((dec.wasCompressed, dec.tag), (true, 'BDEx'));
      expect(dec.bytes, payload);
    });

    test('uncompressed passes through; corrupt zlib and size-mismatch fall back to raw, never throw', () {
      final raw = u8([1, 2, 3, 4, 5]);
      final dec = inflateSection(sec('CONP', raw));
      expect(dec.wasCompressed, isFalse);
      expect(dec.bytes, raw);

      final corrupt = u8([0, 0, 0, 99, 0x78, 0x9c, 1, 2, 3]);
      final c = inflateSection(sec('X', corrupt));
      expect(c.wasCompressed, isFalse);
      expect(c.bytes, corrupt);

      final wrongSize = u8([
        0,
        0,
        3,
        0xe7,
        ...const ZLibEncoder().encode([1, 2, 3]),
      ]);
      expect(inflateSection(sec('Y', wrongSize)).wasCompressed, isFalse, reason: 'declared 999 != inflated 3');
    });
  });

  test('readViSections and decodeSections are total over arbitrary and RSRC-magic-prefixed bytes', () {
    expectTotal(17, 5000, 256, (b) => expect(readViSections(b), isA<List<ViSection>>()));
    expectTotal(3, 3000, 300, (b) => expect(decodeSections(b), isA<List<DecodedSection>>()));
    final rng = Random(4);
    for (var i = 0; i < 5000; i++) {
      final b = Uint8List(32 + rng.nextInt(512));
      b.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      for (var j = 6; j < b.length; j++) {
        b[j] = rng.nextInt(256);
      }
      try {
        readViSections(b);
      } on ViFormatException catch (_) {
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
