import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a synthetic VCTP type pool for the decoder's deterministic
/// (no-corpus) unit tests: a `[u32 count]` header followed by one 4-byte
/// descriptor per code (`[u16 len=4][flags 0x40][typeCode]`).
Uint8List _pool(List<int> codes) => Uint8List.fromList([
      0, 0, 0, codes.length,
      for (final c in codes) ...[0x00, 0x04, 0x40, c],
    ]);

/// A VCTP descriptor: a `u16` length (`2 + body.length`) followed by [body].
List<int> descriptor(List<int> body) =>
    [((2 + body.length) >> 8) & 0xff, (2 + body.length) & 0xff, ...body];

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
    expect(decodeTypePool(Uint8List.fromList([0, 0, 0, 5])), isEmpty);
  });

  test('a truncated descriptor stops cleanly, keeping what parsed', () {
    final b = <int>[0, 0, 0, 3, 0x00, 0x04, 0x40, 0x21, 0x00, 0x04, 0x40, 0x03, 0x00];
    final types = decodeTypePool(Uint8List.fromList(b));
    expect(types.map((t) => t.kind).toList(), [ViDataType.boolean, ViDataType.i32]);
  });

  test('recovers a trailing Pascal name from a descriptor', () {
    const name = 'nine';
    final descBody = <int>[0x40, 0x50, name.length, ...name.codeUnits];
    final b = <int>[0, 0, 0, 1, ...descriptor(descBody)];
    final types = decodeTypePool(Uint8List.fromList(b));
    expect(types.single.kind, ViDataType.cluster);
    expect(types.single.name, 'nine');
  });

  test('a descriptor with no trailing name has a null name', () {
    final types = decodeTypePool(_pool([0x21]));
    expect(types.single.name, isNull);
  });

  test('namedTypes returns only the named entries, in order', () {
    final named = <int>[0x40, 0x50, 2, 0x61, 0x61];
    final unnamed = <int>[0x40, 0x21];
    final b = <int>[
      0, 0, 0, 2,
      ...descriptor(named),
      ...descriptor(unnamed),
    ];
    final types = decodeTypePool(Uint8List.fromList(b));
    final names = namedTypes(types);
    expect(names, hasLength(1));
    expect(names.single.name, 'aa');
  });

  test('decodes a cluster descriptor into resolved member fields', () {
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
    expect(fields[1].name, 'handle');
  });

  test('decodes an array descriptor element type and labels it array<elem>', () {
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a];
    final type1 = <int>[0x00, 0x0c, 0x40, 0x40, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);

    final types = decodeTypePool(b);
    expect(types[1].kind, ViDataType.array);
    expect(types[1].elementIndex, 0);
    expect(typeLabel(types[1], types), 'array<dbl>');
    expect(typeLabel(types[0], types), 'dbl');
  });

  test('decodes enum item labels from an enum descriptor', () {
    final items = <int>[
      0x00, 0x02,
      6, ...'Rising'.codeUnits,
      7, ...'Falling'.codeUnits,
    ];
    final desc = <int>[0x40, 0x16, ...items];
    final b = Uint8List.fromList([0, 0, 0, 1, ...descriptor(desc)]);
    final types = decodeTypePool(b);
    expect(types.single.kind, ViDataType.enumU16);
    expect(types.single.enumItems, ['Rising', 'Falling']);
  });

  test('a non-printable enum item list yields no items (no throw)', () {
    final desc = <int>[0x40, 0x16, 0x00, 0x01, 3, 0x01, 0x02, 0x03];
    final b = Uint8List.fromList([0, 0, 0, 1, ...descriptor(desc)]);
    expect(decodeTypePool(b).single.enumItems, isEmpty);
  });

  test('a 2-D array resolves its element index past the dim-size stride', () {
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a];
    final type1 = <int>[
      0x00, 0x10, 0x40, 0x40,
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x03,
      0x00, 0x00, 0x00, 0x04,
      0x00, 0x00,
    ];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);
    final types = decodeTypePool(b);
    expect(types[1].kind, ViDataType.array);
    expect(types[1].elementIndex, 0,
        reason: 'element index is read past the 2-D dim-size stride, not from a dim-size byte');
    expect(typeLabel(types[1], types), 'array<dbl>');
  });

  test('a binary array tail is NOT mis-read as a trailing name', () {
    final type0 = <int>[0x00, 0x04, 0x40, 0x0a];
    final type1 = <int>[
      0x00, 0x0c, 0x40, 0x40,
      0x00, 0x01,
      0x41, 0x42, 0x43, 0x44,
      0x00, 0x00,
    ];
    final b = Uint8List.fromList([0, 0, 0, 2, ...type0, ...type1]);
    final types = decodeTypePool(b);
    expect(types[1].elementIndex, 0);
    expect(types[1].name, isNull,
        reason: 'dim-size bytes spelling printable "ABCD" are not a name; name scanning is confined to after the element index');
  });

  test('a malformed cluster member list yields no members (no throw)', () {
    final type2 = <int>[0x00, 0x06, 0x40, 0x50, 0x03, 0xe7];
    final b = Uint8List.fromList([0, 0, 0, 1, ...type2]);
    final types = decodeTypePool(b);
    expect(types.single.kind, ViDataType.cluster);
    expect(types.single.members, isEmpty,
        reason: 'a member count of 999 (0x03e7) in a tiny descriptor is rejected');
  });

  test('typeKindHistogram counts kinds, most-frequent first', () {
    final types = decodeTypePool(_pool([0x50, 0x50, 0x30, 0x50, 0x21]));
    final h = typeKindHistogram(types);
    expect(h['cluster'], 3);
    expect(h['string'], 1);
    expect(h['boolean'], 1);
    expect(h.keys.first, 'cluster');
  });
}
