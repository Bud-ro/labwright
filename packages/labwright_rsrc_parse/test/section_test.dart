import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a valid RSRC container with the given blocks/sections, matching the
/// real layout `readViSections` expects: a 32-byte header, a length-prefixed
/// data area (each section stored as `[u32 len][bytes]`), and an info area.
///
/// Info-area field map (after a 32-byte header copy, then 12 filler bytes):
/// `@0x2c` blockListRel (= 0x34), `@0x30` filler, `@0x34` block count. Block
/// entries follow at `@0x38`; their descriptor offsets are stored relative to
/// the block-list header base (`countPos + 8` = `@0x3c`), matching how real .vi
/// files address the section-descriptor table. Each block entry stores
/// `n1 = sectionCount - 1`. Each 20-byte section descriptor is
/// `[idx][dataOffset][0][0][word16]`, where `word16` (`@16`) is `0xFFFFFFFF`
/// for the VI's own data sections and `0` for embedded (LIBN/VINS) sections,
/// which route to `readEmbeddedSections`.
Uint8List buildRsrc(List<({String tag, List<List<int>> sections})> blocks,
    {Set<String> embeddedTags = const {}}) {
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
  final infoOff = 32 + dataBytes.length;

  Uint8List header() {
    final h = BytesBuilder()..add(const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
    be16(h, 3);
    h
      ..add('LVIN'.codeUnits)
      ..add('LBVW'.codeUnits);
    be32(h, infoOff);
    be32(h, 0);
    be32(h, 32);
    be32(h, dataBytes.length);
    return h.toBytes();
  }

  final info = BytesBuilder()..add(header());
  info.add(Uint8List(12));
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

void main() {
  test('extracts each block section with its exact bytes', () {
    final rsrc = buildRsrc([
      (tag: 'vers', sections: [
        [1, 2, 3, 4],
        [9, 9],
      ]),
      (tag: 'BDHb', sections: [
        [0xde, 0xad, 0xbe, 0xef, 0x10],
      ]),
    ]);

    final secs = readViSections(rsrc);
    expect(secs.map((s) => '${s.tag}#${s.index}'), ['vers#0', 'vers#1', 'BDHb#0']);
    expect(secs[0].bytes, [1, 2, 3, 4]);
    expect(secs[1].bytes, [9, 9]);
    expect(secs[2].bytes, [0xde, 0xad, 0xbe, 0xef, 0x10]);

    final bd = secs.firstWhere((s) => s.tag == 'BDHb');
    expect(bd.bytes.length, 5);
  });

  test('readEmbeddedSections returns LIBN/VINS (word16==0); readViSections excludes them', () {
    final nested = buildRsrc([
      (tag: 'vers', sections: [
        [9, 9],
      ]),
    ]);
    final rsrc = buildRsrc([
      (tag: 'vers', sections: [
        [1, 2, 3, 4],
      ]),
      (tag: 'LIBN', sections: [
        'My.lvlib'.codeUnits,
      ]),
      (tag: 'VINS', sections: [nested]),
    ], embeddedTags: {'LIBN', 'VINS'});

    expect(readViSections(rsrc).map((s) => s.tag), ['vers'],
        reason: 'primary reader sees only the VI\'s own data section');

    final emb = readEmbeddedSections(rsrc);
    expect(emb.map((s) => '${s.tag}#${s.index}'), ['LIBN#0', 'VINS#0']);
    expect(String.fromCharCodes(emb[0].bytes), 'My.lvlib');
    expect(emb[1].bytes.sublist(0, 4), [0x52, 0x53, 0x52, 0x43]);
    expect(String.fromCharCodes(emb[1].bytes.sublist(8, 12)), 'LVIN');
    expect(ViContainer.parse(emb[1].bytes).parsedHeader.fileType, 'LVIN');
  });

  test('returns bytes as-stored (no inflation at this layer)', () {
    final payload = [0, 0, 0, 8, 0x78, 0x9c, 1, 2, 3, 4];
    final secs = readViSections(buildRsrc([(tag: 'BDEx', sections: [payload])]));
    expect(secs.single.bytes, payload,
        reason: 'a zlib-looking payload ([u32 decompSize][0x78 0x9c ...]) is returned '
            'untouched; inflation happens later in videcode');
  });

  test('an empty container (no blocks) yields no sections', () {
    expect(readViSections(buildRsrc(const [])), isEmpty);
  });

  test('totality: arbitrary bytes never crash (ViFormatException or a list)', () {
    final rng = Random(17);
    for (var i = 0; i < 5000; i++) {
      final n = rng.nextInt(256);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        final secs = readViSections(b);
        expect(secs, isA<List<ViSection>>());
      } on ViFormatException {
        // acceptable
      } catch (e) {
        fail('readViSections leaked ${e.runtimeType} on ${b.length} bytes: $e');
      }
    }
  });

  test('totality: RSRC-magic-prefixed junk never crashes', () {
    final rng = Random(4);
    for (var i = 0; i < 5000; i++) {
      final n = 32 + rng.nextInt(512);
      final b = Uint8List(n);
      b.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      for (var j = 6; j < n; j++) {
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
