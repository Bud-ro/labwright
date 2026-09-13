import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

const _lv20 = ViVersionWord(major: 20, minor: 0, patch: 0, stage: 0x80, build: 0);

const _lv8 = ViVersionWord(major: 8, minor: 5, patch: 0, stage: 0x80, build: 0);

List<int> _str(String text) => [...be32(text.length), ...text.codeUnits];

/// A LabVIEW 20 variant naming top-level type [topLevel], its value, and named [attributes].
List<int> _variant(int topLevel, List<int> value, [Map<String, List<int>> attributes = const {}]) => [
  0x20, 0x00, 0x80, 0x00, //
  ...be16(topLevel),
  ...value,
  ...be32(attributes.length),
  for (final MapEntry(:key, :value) in attributes.entries) ...[..._str(key), ...value],
];

void main() {
  final pool = decodeTypePool(
    poolOf(
      [
        numeric(TypeCode.i32, name: 'n'),
        descriptor(TypeCode.string, [0xff, 0xff, 0xff, 0xff], name: 's'),
        descriptor(TypeCode.cluster, [0, 2, 0, 0, 0, 1], name: 'c'),
        descriptor(TypeCode.array, [0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0], name: 'a'),
        descriptor(TypeCode.variant, [], name: 'v'),
        descriptor(TypeCode.boolean, [], name: 'b'),
        descriptor(TypeCode.cluster, [0, 4, 0, 0, 0, 1, 0, 0, 0, 5], name: 'history'),
        descriptor(TypeCode.measureData, [0, 6], name: 't0'),
        descriptor(TypeCode.refnum, [0, 14], name: 'visa'),
        descriptor(TypeCode.path, [0xff, 0xff, 0xff, 0xff], name: 'p'),
      ],
      topLevel: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    ),
  );

  ViDataSpace decode(List<int> flags, List<int> body, {ViVersionWord version = _lv20}) {
    final map = decodeTypeMap(u8([...be16(flags.length), 0, 1, for (final f in flags) ...be16(f)])) as ViTypeMapIndexed;
    return decodeDataSpace(u8(body), DfdsContext.indexed(pool, map, version));
  }

  test('each stored entry is one slot laid out by its type; unstored and special entries take none', () {
    final rows = <(String, List<int>, List<int>, List<(int, int, int)>)>[
      ('i32 and string', [0x2000, 0x2000], [...be32(7), ..._str('abc')], [(0, 0, 4), (1, 4, 7)]),
      (
        'unstored flags skip the entry',
        [0x0008, 0x2000, 0x0400, 0x2000, 0x0800],
        [..._str(''), ...be32(1), ...be32(5)],
        [(1, 0, 4), (3, 4, 8)],
      ),
      ('bit 0 stores like bit 13', [0x0001], [...be32(9)], [(0, 0, 4)]),
      ('a cluster is its members', [0, 0, 0x2000], [...be32(1), ..._str('xy')], [(2, 0, 10)]),
      (
        'an array is its dimension sizes then elements',
        [0, 0, 0, 0x2000],
        [...be32(2), ...be32(5), ...be32(6)],
        [(3, 0, 12)],
      ),
      (
        'a variant names a top-level type, holds its value and its attributes',
        [0, 0, 0, 0, 0x2000],
        _variant(2, _str('hi'), {'key': _variant(0, [])}),
        [(4, 0, 6 + 6 + 4 + 7 + 10)],
      ),
      ('an empty variant has type 0', [0, 0, 0, 0, 0x2000], _variant(0, []), [(4, 0, 10)]),
      ('a boolean is one byte', [0, 0, 0, 0, 0, 0x2000], [1], [(5, 0, 1)]),
      (
        'a chart-history cluster stores members 1, 2 and 3 without a slot',
        [0, 0, 0, 0, 0, 0, 0x0010, 0x2000],
        [..._str('m1'), ...be32(3), 1, ...List.filled(16, 0)],
        [(7, 11, 16)],
      ),
      (
        'a front-panel operation cluster stores member 1 from LabVIEW 10, and skips it under bit 9',
        [0, 0, 0, 0, 0, 0, 0x0204, 0x2000],
        List.filled(16, 0),
        [(7, 0, 16)],
      ),
      ('a timestamp is 16 bytes', [0, 0, 0, 0, 0, 0, 0, 0x2000], List.filled(16, 0), [(7, 0, 16)]),
      ('a VISA refnum is a counted resource name', [0, 0, 0, 0, 0, 0, 0, 0, 0x2000], _str('GPIB0'), [(8, 0, 9)]),
      (
        'a path is PTH0, a length and the bytes',
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2000],
        [...'PTH0'.codeUnits, ...be32(2), 0, 0],
        [(9, 0, 10)],
      ),
    ];
    for (final (name, flags, body, slots) in rows) {
      final space = decode(flags, body);
      expect(
        [for (final slot in space.slots) (slot.entryIndex, slot.offset, slot.length)],
        slots,
        reason: name,
      );
      expect(space.serialize(), same(space.bytes), reason: name);
    }
    final ordered = decode([0, 0, 0, 0, 0, 0, 0x0004, 0x2000], [...be32(1), ...List.filled(16, 0)], version: _lv8);
    expect(ordered.slots.single.offset, 4, reason: 'before LabVIEW 10 the operation cluster stores member 2');
    final first = decode([0x2000, 0x2000], [...be32(7), ..._str('abc')]);
    expect(first.slotAt(1).topLevelIndex, 1);
    expect(first.slotBytes(1), [0, 0, 0, 3, 0x61, 0x62, 0x63]);
  });

  test('a body that does not tile violates the precondition', () {
    final rows = <(String, List<int>, List<int>)>[
      ('short numeric', [0x2000], [0, 0]),
      ('string past the end', [0, 0x2000], [...be32(4), 0x61]),
      ('trailing bytes', [0x2000], [...be32(1), 0]),
      ('variant naming a top-level type past the pool', [0, 0, 0, 0, 0x2000], _variant(11, [])),
      ('entry past the top-level list', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2000], []),
    ];
    for (final (name, flags, body) in rows) {
      expect(() => decode(flags, body), throwsA(isA<AssertionError>()), reason: name);
    }
  });

  test('the inline map form lays the space out by its own descriptors', () {
    final map =
        decodeTypeMap(
              u8([
                0,
                0,
                0,
                2,
                ...descriptor(TypeCode.u16, []),
                ...descriptor(TypeCode.cluster, [0, 2, 0, 0, 0, 0]),
                ...hx('0002 0000 2000 0001 2000'),
              ]),
            )
            as ViTypeMapInline;
    final space = decodeDataSpace(u8([1, 2, 3, 4, 5, 6]), DfdsContext.inline(map, _lv8));
    expect([for (final slot in space.slots) (slot.topLevelIndex, slot.offset, slot.length)], [(0, 0, 2), (1, 2, 4)]);
  });

  test('dataSpaceContexts pairs each DFDS with the TM80 of its index and needs a version word', () {
    final vers = u8([0x20, 0x00, 0x80, 0x00, 0, 0, 3, ...'20.0'.codeUnits.take(3), 0]);
    ViSection section(String tag, int index, Uint8List bytes) =>
        ViSection(tag: tag, index: index, dataOffset: 0, bytes: bytes);
    final tm80 = u8(hx('0001 0001 2000'));
    final contexts = dataSpaceContexts([
      section('vers', 0, vers),
      section('VCTP', 0, pool.bytes),
      section('TM80', 0, tm80),
      section('TM80', 2, tm80),
      section('DFDS', 0, u8([])),
      section('DFDS', 2, u8([])),
      section('DFDS', 5, u8([])),
    ]);
    expect(contexts.keys, [0, 2, 5]);
    expect(contexts[5]!.typeMap, same(contexts[0]!.typeMap));
    expect(
      dataSpaceContexts([section('VCTP', 0, pool.bytes), section('TM80', 0, tm80), section('DFDS', 0, u8([]))]),
      isEmpty,
    );
    expect(
      dataSpaceContexts([section('vers', 0, vers), section('TM80', 0, tm80), section('DFDS', 0, u8([]))]),
      isEmpty,
    );
  });
}
