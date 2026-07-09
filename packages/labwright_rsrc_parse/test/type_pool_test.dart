import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// A synthetic VCTP pool: `[u32 count]` ++ one 4-byte descriptor per code (`[u16 len=4][0x40][code]`).
Uint8List _pool(List<int> codes) => u8([
  0, 0, 0, codes.length, //
  for (final c in codes) ...[0x00, 0x04, 0x40, c],
]);

/// A VCTP descriptor: `[u16 len = 2 + body.length]` ++ body.
List<int> descriptor(List<int> body) => [((2 + body.length) >> 8) & 0xff, (2 + body.length) & 0xff, ...body];

void main() {
  test('decodes well-known type codes to their kinds; uncatalogued codes keep their raw byte', () {
    const rows = <(int, ViDataType)>[
      (0x21, ViDataType.boolean),
      (0x03, ViDataType.i32),
      (0x07, ViDataType.u32),
      (0x0a, ViDataType.dbl),
      (0x30, ViDataType.string),
      (0x40, ViDataType.array),
      (0x50, ViDataType.cluster),
      (0x70, ViDataType.refnum),
      (0x16, ViDataType.enumU16),
    ];
    final types = decodeTypePool(_pool([for (final (code, _) in rows) code]));
    expect(types.map((t) => t.kind), [for (final (_, kind) in rows) kind]);
    expect((types.first.index, types.first.code), (0, 0x21));

    final unknown = decodeTypePool(_pool([0x80])).single;
    expect((unknown.kind, unknown.code), (ViDataType.unknown, 0x80));
  });

  test('total on short/empty pools; a truncated descriptor stops cleanly, keeping what parsed', () {
    expect(decodeTypePool(Uint8List(0)), isEmpty);
    expect(decodeTypePool(u8([0, 0, 0, 5])), isEmpty);
    final types = decodeTypePool(u8([0, 0, 0, 3, 0x00, 0x04, 0x40, 0x21, 0x00, 0x04, 0x40, 0x03, 0x00]));
    expect(types.map((t) => t.kind), [ViDataType.boolean, ViDataType.i32]);
  });

  test('trailing Pascal names: recovered when present, null otherwise; namedTypes filters in order', () {
    final named = decodeTypePool(
      u8([
        0,
        0,
        0,
        1,
        ...descriptor([0x40, 0x50, ...pascal('nine')]),
      ]),
    ).single;
    expect((named.kind, named.name), (ViDataType.cluster, 'nine'));
    expect(decodeTypePool(_pool([0x21])).single.name, isNull);

    final two = decodeTypePool(
      u8([
        0,
        0,
        0,
        2,
        ...descriptor([0x40, 0x50, ...pascal('aa')]),
        ...descriptor([0x40, 0x21]),
      ]),
    );
    expect(namedTypes(two).map((t) => t.name), ['aa']);
  });

  test('cluster descriptors resolve member indices into fields; malformed member lists yield none', () {
    const t1Name = 'handle';
    final b = u8([
      0, 0, 0, 3, //
      0x00, 0x04, 0x40, 0x21, // 0: boolean
      0x00, 0x0b, 0x40, 0x03, t1Name.length, ...t1Name.codeUnits, // 1: i32 "handle"
      0x00, 0x0a, 0x40, 0x50, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, // 2: cluster{0,1}
    ]);
    final types = decodeTypePool(b);
    final cluster = types[2];
    expect((cluster.kind, types.length), (ViDataType.cluster, 3));
    expect(cluster.members, [0, 1]);
    final fields = clusterFields(cluster, types);
    expect(fields.map((f) => f.kind), [ViDataType.boolean, ViDataType.i32]);
    expect(fields[1].name, 'handle');

    final bad = decodeTypePool(u8([0, 0, 0, 1, 0x00, 0x06, 0x40, 0x50, 0x03, 0xe7])).single;
    expect(bad.kind, ViDataType.cluster);
    expect(bad.members, isEmpty, reason: 'member count 999 in a tiny descriptor is rejected');
  });

  test('serializedDefaultSize: fixed-width leaves, cluster is the member sum, variable/unknown are null', () {
    // One descriptor per code; check the flattened default width of each.
    final types = decodeTypePool(
      _pool([
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x0a,
        0x0b,
        0x0e,
        0x15,
        0x16,
        0x17,
        0x21,
        0x70,
        0x30,
        0x40,
        0x53,
        0x80,
        0xf1,
      ]),
    );
    int? sz(int i) => serializedDefaultSize(types[i], types);
    expect(
      [for (var i = 0; i < 13; i++) sz(i)],
      [
        0, // void
        1, // i8
        2, // i16
        4, // i32
        8, // i64
        8, // dbl
        16, // ext
        32, // complexExt
        1, // enumU8
        2, // enumU16
        4, // enumU32
        1, // boolean
        4, // refnum
      ],
    );
    // string, array, variant, unknown 0x80, typedef 0xf1 — not derivable.
    expect([for (var i = 13; i < 18; i++) sz(i)], [null, null, null, null, null]);

    // Cluster{boolean, i32, dbl} = 1 + 4 + 8 = 13.
    final cl = decodeTypePool(
      u8([
        0, 0, 0, 4, //
        0x00, 0x04, 0x40, 0x21, // 0: boolean
        0x00, 0x04, 0x40, 0x03, // 1: i32
        0x00, 0x04, 0x40, 0x0a, // 2: dbl
        0x00, 0x0c, 0x40, 0x50, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, // 3: cluster{0,1,2}
      ]),
    );
    expect(serializedDefaultSize(cl[3], cl), 13);

    // A cluster with a variable member (string) is not derivable.
    final clv = decodeTypePool(
      u8([
        0, 0, 0, 2, //
        0x00, 0x04, 0x40, 0x30, // 0: string
        0x00, 0x08, 0x40, 0x50, 0x00, 0x01, 0x00, 0x00, // 1: cluster{0}
      ]),
    );
    expect(serializedDefaultSize(clv[1], clv), isNull);
  });

  test('array descriptors: element type, array<elem> label, 2-D dim stride, binary tail not a name', () {
    final oneD = decodeTypePool(u8([0, 0, 0, 2, ...hx('0004 400a'), ...hx('000c 4040 0001 ffffffff 0000')]));
    expect((oneD[1].kind, oneD[1].elementIndex), (ViDataType.array, 0));
    expect(typeLabel(oneD[1], oneD), 'array<dbl>');
    expect(typeLabel(oneD[0], oneD), 'dbl');

    final twoD = decodeTypePool(u8([0, 0, 0, 2, ...hx('0004 400a'), ...hx('0010 4040 0002 00000003 00000004 0000')]));
    expect(twoD[1].elementIndex, 0, reason: 'element index read past the 2-D dim-size stride');
    expect(typeLabel(twoD[1], twoD), 'array<dbl>');

    final binTail = decodeTypePool(u8([0, 0, 0, 2, ...hx('0004 400a'), ...hx('000c 4040 0001 41424344 0000')]));
    expect(binTail[1].elementIndex, 0);
    expect(binTail[1].name, isNull, reason: 'dim-size bytes spelling printable "ABCD" are not a name');
  });

  test('enum descriptors: item labels recovered; non-printable item lists yield none (no throw)', () {
    final items = [0x00, 0x02, ...pascal('Rising'), ...pascal('Falling')];
    final e = decodeTypePool(
      u8([
        0,
        0,
        0,
        1,
        ...descriptor([0x40, 0x16, ...items]),
      ]),
    ).single;
    expect((e.kind, e.enumItems.length), (ViDataType.enumU16, 2));
    expect(e.enumItems, ['Rising', 'Falling']);

    final bad = decodeTypePool(
      u8([
        0,
        0,
        0,
        1,
        ...descriptor([0x40, 0x16, 0x00, 0x01, 3, 0x01, 0x02, 0x03]),
      ]),
    );
    expect(bad.single.enumItems, isEmpty);
  });

  test('typeKindHistogram counts kinds, most-frequent first', () {
    final h = typeKindHistogram(decodeTypePool(_pool([0x50, 0x50, 0x30, 0x50, 0x21])));
    expect((h['cluster'], h['string'], h['boolean'], h.keys.first), (3, 1, 1, 'cluster'));
  });
}
