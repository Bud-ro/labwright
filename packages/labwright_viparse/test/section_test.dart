import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

/// Builds a valid RSRC container with the given blocks/sections, matching the
/// real layout `readViSections` expects: a 32-byte header, a length-prefixed
/// data area, and an info area whose block list points at 20-byte section
/// descriptors terminated by the 0xFFFFFFFF sentinel.
Uint8List buildRsrc(List<({String tag, List<List<int>> sections})> blocks) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  // --- data area: per section [u32 len][bytes], record each section offset ---
  final data = BytesBuilder();
  final secOff = <String, int>{}; // "bi.si" -> offset within data
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
    be32(h, 0); // info size (unused by reader)
    be32(h, 32); // data offset
    be32(h, dataBytes.length); // data size
    return h.toBytes();
  }

  // --- info area ---
  final info = BytesBuilder()..add(header()); // 0..31: header copy
  info.add(Uint8List(12)); // 0x20..0x2c filler
  be32(info, 0x34); // 0x2c: blockListRel
  be32(info, 0); // 0x30: filler
  be32(info, blocks.length); // 0x34: block count
  // Descriptor offsets are stored relative to the block-list header base
  // (`countPos + 8` = info+0x3c), matching how real .vi files address the
  // section-descriptor table. The descriptors are packed after the entry list.
  const descBase = 0x3c; // = countPos(0x34) + 8
  var off = (0x38 + blocks.length * 12) - descBase;
  final n2 = <int>[];
  for (final b in blocks) {
    n2.add(off);
    off += b.sections.length * 20;
  }
  for (var bi = 0; bi < blocks.length; bi++) {
    info.add(blocks[bi].tag.codeUnits);
    be32(info, blocks[bi].sections.length - 1); // n1 = count - 1
    be32(info, n2[bi]);
  }
  for (var bi = 0; bi < blocks.length; bi++) {
    for (var si = 0; si < blocks[bi].sections.length; si++) {
      be32(info, si); // idx
      be32(info, secOff['$bi.$si']!); // data offset
      be32(info, 0);
      be32(info, 0);
      be32(info, 0xFFFFFFFF); // sentinel
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

    // the BDHb section is reachable by tag
    final bd = secs.firstWhere((s) => s.tag == 'BDHb');
    expect(bd.bytes.length, 5);
  });

  test('returns bytes as-stored (no inflation at this layer)', () {
    // A "compressed-looking" payload: [u32 decompSize][zlib magic 0x78 ...].
    final payload = [0, 0, 0, 8, 0x78, 0x9c, 1, 2, 3, 4];
    final secs = readViSections(buildRsrc([(tag: 'BDEx', sections: [payload])]));
    expect(secs.single.bytes, payload); // untouched; videcode will inflate
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
