import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Deterministic (no-corpus) unit tests for the VCTP type-pool decoder. Builds a
// synthetic pool ([u32 count] + descriptors [u16 len][flags][code]) so the
// known-code -> kind mapping and the unknown-code fallback are pinned exactly.

Uint8List _pool(List<int> codes) {
  final b = <int>[0, 0, 0, codes.length]; // u32 count
  for (final c in codes) {
    b.addAll([0x00, 0x04, 0x40, c]); // descLen=4, flags=0x40, typeCode=c
  }
  return Uint8List.fromList(b);
}

void main() {
  test('decodes well-known type codes to their kinds', () {
    final types = decodeTypePool(_pool([0x21, 0x03, 0x07, 0x0a, 0x30, 0x40, 0x50, 0x70, 0x16]));
    expect(types.map((t) => t.kind).toList(), [
      ViDataType.boolean,
      ViDataType.i32,
      ViDataType.u32,
      ViDataType.dbl,
      ViDataType.string,
      ViDataType.array,
      ViDataType.cluster,
      ViDataType.refnum,
      ViDataType.enumU16,
    ]);
    // index + raw code are preserved
    expect(types.first.index, 0);
    expect(types.first.code, 0x21);
  });

  test('an uncatalogued code decodes to unknown but keeps its raw byte', () {
    final types = decodeTypePool(_pool([0xf0]));
    expect(types, hasLength(1));
    expect(types.single.kind, ViDataType.unknown);
    expect(types.single.code, 0xf0);
  });

  test('a short/empty pool decodes to an empty list (total, no throw)', () {
    expect(decodeTypePool(Uint8List(0)), isEmpty);
    expect(decodeTypePool(Uint8List.fromList([0, 0, 0, 5])), isEmpty); // count=5 but no descriptors
  });

  test('a truncated descriptor stops cleanly, keeping what parsed', () {
    // count says 3, but only 2 full descriptors are present
    final b = <int>[0, 0, 0, 3, 0x00, 0x04, 0x40, 0x21, 0x00, 0x04, 0x40, 0x03, 0x00];
    final types = decodeTypePool(Uint8List.fromList(b));
    expect(types.map((t) => t.kind).toList(), [ViDataType.boolean, ViDataType.i32]);
  });

  test('recovers a trailing Pascal name from a descriptor', () {
    // count=1; descriptor: [u16 len][flags 0x40][code 0x50 cluster][u8 nameLen=4]["nine"]
    const name = 'nine';
    final descBody = <int>[0x40, 0x50, name.length, ...name.codeUnits]; // after the len word
    final descLen = 2 + descBody.length;
    final b = <int>[0, 0, 0, 1, (descLen >> 8) & 0xff, descLen & 0xff, ...descBody];
    final types = decodeTypePool(Uint8List.fromList(b));
    expect(types.single.kind, ViDataType.cluster);
    expect(types.single.name, 'nine');
  });

  test('a descriptor with no trailing name has a null name', () {
    final types = decodeTypePool(_pool([0x21])); // descLen=4, no name bytes
    expect(types.single.name, isNull);
  });

  test('namedTypes returns only the named entries, in order', () {
    // build two descriptors: first named "aa", second unnamed
    final named = <int>[0x40, 0x50, 2, 0x61, 0x61]; // cluster "aa"
    final namedLen = 2 + named.length;
    final unnamed = <int>[0x40, 0x21]; // bool, no name
    final unnamedLen = 2 + unnamed.length;
    final b = <int>[
      0, 0, 0, 2,
      (namedLen >> 8) & 0xff, namedLen & 0xff, ...named,
      (unnamedLen >> 8) & 0xff, unnamedLen & 0xff, ...unnamed,
    ];
    final types = decodeTypePool(Uint8List.fromList(b));
    final names = namedTypes(types);
    expect(names, hasLength(1));
    expect(names.single.name, 'aa');
  });

  test('typeKindHistogram counts kinds, most-frequent first', () {
    final types = decodeTypePool(_pool([0x50, 0x50, 0x30, 0x50, 0x21]));
    final h = typeKindHistogram(types);
    expect(h['cluster'], 3);
    expect(h['string'], 1);
    expect(h['boolean'], 1);
    expect(h.keys.first, 'cluster'); // ordered by frequency
  });
}
