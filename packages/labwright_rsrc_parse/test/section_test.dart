import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// Builds a valid RSRC container with the given blocks/sections in the real layout `readViSections`
/// expects: 32-byte header ++ `[u32 len][bytes]` data sections ++ info area (subheader @0x2c -> block
/// list @0x34, descriptor offsets relative to the block-list header base @0x3c, 20-byte descriptors
/// whose word16 is 0xFFFFFFFF for own-data sections and 0 for embedded LIBN/VINS sections).
Uint8List buildRsrc(List<({String tag, List<List<int>> sections})> blocks, {Set<String> embeddedTags = const {}}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  final data = BytesBuilder();
  final secOff = <String, int>{};
  for (var bi = 0; bi < blocks.length; bi++) {
    for (var si = 0; si < blocks[bi].sections.length; si++) {
      secOff['$bi.$si'] = data.length;
      be32(data, blocks[bi].sections[si].length);
      data.add(blocks[bi].sections[si]);
    }
  }
  final dataBytes = data.toBytes();

  Uint8List header() {
    final h = BytesBuilder()..add(const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
    be16(h, 3);
    h
      ..add('LVIN'.codeUnits)
      ..add('LBVW'.codeUnits);
    be32(h, 32 + dataBytes.length);
    be32(h, 0);
    be32(h, 32);
    be32(h, dataBytes.length);
    return h.toBytes();
  }

  final info = BytesBuilder()
    ..add(header())
    ..add(Uint8List(12));
  be32(info, 0x34);
  be32(info, 0);
  be32(info, blocks.length);
  const descBase = 0x3c;
  var off = (0x38 + blocks.length * 12) - descBase;
  final descOffsets = <int>[];
  for (final b in blocks) {
    descOffsets.add(off);
    off += b.sections.length * 20;
  }
  for (var bi = 0; bi < blocks.length; bi++) {
    info.add(blocks[bi].tag.codeUnits);
    be32(info, blocks[bi].sections.length - 1);
    be32(info, descOffsets[bi]);
  }
  for (var bi = 0; bi < blocks.length; bi++) {
    for (var si = 0; si < blocks[bi].sections.length; si++) {
      be32(info, si);
      be32(info, secOff['$bi.$si']!);
      be32(info, 0);
      be32(info, 0);
      be32(info, embeddedTags.contains(blocks[bi].tag) ? 0 : 0xFFFFFFFF);
    }
  }

  return (BytesBuilder()
        ..add(header())
        ..add(dataBytes)
        ..add(info.toBytes()))
      .toBytes();
}

/// Wraps [payload] as a stored heap section: `[u32 decompressedSize][zlib stream]`.
Uint8List compressedSection(List<int> payload) {
  final z = const ZLibEncoder().encode(payload);
  return u8([...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(), ...z]);
}

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
      ],
      embeddedTags: {'LIBN', 'VINS'},
    );
    expect(readViSections(rsrc).map((s) => s.tag), ['vers'], reason: 'primary reader sees only own data');
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
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('leaked ${e.runtimeType}: $e');
      }
    }
  });
}
