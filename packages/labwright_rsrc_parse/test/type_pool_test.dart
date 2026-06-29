import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
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

  test('decodes a cluster descriptor into resolved member fields', () {
    // pool of 3 types: [0]=bool, [1]=i32 named "handle", [2]=cluster{0,1}
    // type0: descLen=4 [00 04][40 21]
    // type1: i32 named "handle": [40 03][nameLen=6]"handle" -> body 2+1+6=9, descLen=11
    // type2: cluster, 2 members idx 0,1: [40 50][u16 nm=2][u16 0][u16 1] -> body 2+2+2+2=8, descLen=10
    const t1Name = 'handle';
    final type0 = <int>[0x00, 0x04, 0x40, 0x21];
    final type1 = <int>[0x00, 0x0b, 0x40, 0x03, t1Name.length, ...t1Name.codeUnits];
    final type2 = <int>[0x00, 0x0a, 0x40, 0x50, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01];
    final b = Uint8List.fromList([0, 0, 0, 3, ...type0, ...type1, ...type2]);

    final types = decodeTypePool(b);
    expect(types, hasLength(3));
    final cluster = types[2];
    expect(cluster.kind, ViDataType.cluster);
    expect(cluster.members, [0, 1]);

    final fields = clusterFields(cluster, types);
    expect(fields.map((f) => f.kind).toList(), [ViDataType.boolean, ViDataType.i32]);
    expect(fields[1].name, 'handle'); // member 1 resolves to the named i32
  });

  test('decodes an array descriptor element type and labels it array<elem>', () {
    // pool: [0]=dbl, [1]=1-D array of [0]
    // type0: dbl: descLen=4 [00 04][40 0a]
    // type1: array: [40 40][u16 numDims=1][u32 dimSize=ffffffff][u16 elemIdx=0]
    //   body after len = flags,code(2) + numDims(2) + dimSize(4) + elemIdx(2) = 10; descLen=12
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a];
    final type1 = <int>[0x00, 0x0c, 0x40, 0x40, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);

    final types = decodeTypePool(b);
    expect(types[1].kind, ViDataType.array);
    expect(types[1].elementIndex, 0);
    expect(typeLabel(types[1], types), 'array<dbl>');
    expect(typeLabel(types[0], types), 'dbl'); // non-array unchanged
  });

  test('decodes enum item labels from an enum descriptor', () {
    // enum (0x16) with 2 items "Rising","Falling": body after len =
    // flags,code(2) + numItems(2) + [len+"Rising"](7) + [len+"Falling"](8) = 19; descLen=21
    final items = <int>[
      0x00, 0x02, // numItems=2
      6, ...'Rising'.codeUnits,
      7, ...'Falling'.codeUnits,
    ];
    final desc = <int>[0x40, 0x16, ...items];
    final descLen = 2 + desc.length;
    final b = Uint8List.fromList([0, 0, 0, 1, (descLen >> 8) & 0xff, descLen & 0xff, ...desc]);
    final types = decodeTypePool(b);
    expect(types.single.kind, ViDataType.enumU16);
    expect(types.single.enumItems, ['Rising', 'Falling']);
  });

  test('a non-printable enum item list yields no items (no throw)', () {
    final desc = <int>[0x40, 0x16, 0x00, 0x01, 3, 0x01, 0x02, 0x03]; // 1 item, non-printable
    final descLen = 2 + desc.length;
    final b = Uint8List.fromList([0, 0, 0, 1, (descLen >> 8) & 0xff, descLen & 0xff, ...desc]);
    expect(decodeTypePool(b).single.enumItems, isEmpty);
  });

  test('a 2-D array resolves its element index past the dim-size stride', () {
    // pool: [0]=dbl, [1]=2-D array of [0]
    // type1 body: flags,code(2) + numDims=2(2) + dimSize0(4) + dimSize1(4) + elemIdx(2) = 14; descLen=16
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a];
    final type1 = <int>[
      0x00, 0x10, 0x40, 0x40, // descLen=16, flags, code=array
      0x00, 0x02, // numDims=2
      0x00, 0x00, 0x00, 0x03, // dim0 size
      0x00, 0x00, 0x00, 0x04, // dim1 size
      0x00, 0x00, // elemIdx=0
    ];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);
    final types = decodeTypePool(b);
    expect(types[1].kind, ViDataType.array);
    expect(types[1].elementIndex, 0); // not mis-read from a dim-size byte
    expect(typeLabel(types[1], types), 'array<dbl>');
  });

  test('a binary array tail is NOT mis-read as a trailing name', () {
    // array whose dim size bytes spell printable ASCII ("ABCD") must not yield a
    // name — name scanning is confined to after the element index.
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a]; // dbl
    final type1 = <int>[
      0x00, 0x0c, 0x40, 0x40, // descLen=12, flags, array
      0x00, 0x01, // numDims=1
      0x41, 0x42, 0x43, 0x44, // dim size = "ABCD" (printable, but binary)
      0x00, 0x00, // elemIdx=0
    ];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);
    final types = decodeTypePool(b);
    expect(types[1].elementIndex, 0);
    expect(types[1].name, isNull); // the "ABCD" dim bytes are not a name
  });

  test('a malformed cluster member list yields no members (no throw)', () {
    // cluster claiming 999 members in a tiny descriptor -> rejected
    final type2 = <int>[0x00, 0x06, 0x40, 0x50, 0x03, 0xe7]; // nm=999, descLen=6
    final b = Uint8List.fromList([0, 0, 0, 1, ...type2]);
    final types = decodeTypePool(b);
    expect(types.single.kind, ViDataType.cluster);
    expect(types.single.members, isEmpty);
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
