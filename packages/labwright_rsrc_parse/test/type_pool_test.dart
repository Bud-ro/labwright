import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> label(String text) => [text.length, ...text.codeUnits, if (text.length.isEven) 0];

List<int> descriptor(int code, List<int> body, {String? name, int flags = 0}) {
  final rest = [name == null ? flags : flags | 0x40, code, ...body, if (name != null) ...label(name)];
  return [((2 + rest.length) >> 8) & 0xff, (2 + rest.length) & 0xff, ...rest];
}

List<int> numeric(int code, {String? name}) => descriptor(code, [0], name: name);

Uint8List poolOf(List<List<int>> descriptors, {List<int> topLevel = const []}) => u8([
  0, 0, 0, descriptors.length, //
  for (final d in descriptors) ...d,
  0, topLevel.length,
  for (final i in topLevel) ...[i >> 8, i & 0xff],
]);

void main() {
  test('every type code decodes to its kind; an unlisted code is unknown and retained', () {
    const rows = <(int, ViDataType)>[
      (TypeCode.boolean, ViDataType.boolean),
      (TypeCode.i32, ViDataType.i32),
      (TypeCode.u32, ViDataType.u32),
      (TypeCode.dbl, ViDataType.dbl),
      (TypeCode.string, ViDataType.string),
      (TypeCode.path, ViDataType.path),
      (TypeCode.variant, ViDataType.variant),
      (TypeCode.ptr, ViDataType.ptr),
    ];
    final pool = decodeTypePool(
      poolOf([
        for (final (code, _) in rows)
          switch (code) {
            TypeCode.i32 || TypeCode.u32 || TypeCode.dbl => numeric(code),
            TypeCode.string || TypeCode.path => descriptor(code, [0xff, 0xff, 0xff, 0xff]),
            _ => descriptor(code, []),
          },
        descriptor(0x31, [1, 2, 3]),
      ]),
    );
    expect(pool.types.map((t) => t.kind), [for (final (_, kind) in rows) kind, ViDataType.unknown]);
    expect((pool[0].code, pool[0].label), (TypeCode.boolean, null));
    expect(pool[0].undecoded, isEmpty);
    final unknown = pool.types.last;
    expect(unknown.code, 0x31);
    expect(unknown.undecoded, [1, 2, 3]);
    expect(pool.serialize(), same(pool.bytes));
  });

  test('labels: flag 0x40 marks a Pascal label after the body, padded to an even length', () {
    final pool = decodeTypePool(
      poolOf([
        numeric(TypeCode.i16, name: 'y'),
        numeric(TypeCode.u32, name: 'Time'),
        descriptor(TypeCode.boolean, [], name: 'status'),
        descriptor(TypeCode.variant, [], name: 'X'),
        numeric(TypeCode.i8),
      ]),
    );
    expect(pool.types.map((t) => t.label), ['y', 'Time', 'status', 'X', null]);
    expect(pool.types.map((t) => t.hasLabel), [true, true, true, true, false]);
    expect((pool[1] as ViNumericType).property, 0);
    expect(namedTypes(pool.types).map((t) => t.label), ['y', 'Time', 'status', 'X']);
    expect(
      () => decodeTypePool(
        poolOf([
          u8([0, 6, 0x40, TypeCode.i16, 0, 9]),
        ]),
      ),
      throwsA(isA<AssertionError>()),
      reason: 'the label must end the descriptor',
    );
  });

  test('clusters index their members; fields resolve against the pool', () {
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.boolean, []),
        numeric(TypeCode.i32, name: 'handle'),
        descriptor(TypeCode.cluster, [0, 2, 0, 0, 0, 1], name: 'pair'),
      ]),
    );
    final cluster = pool[2] as ViClusterType;
    expect((cluster.memberCount, cluster.label), (2, 'pair'));
    expect(cluster.memberIndices, [0, 1]);
    final fields = clusterFields(cluster, pool.types);
    expect(fields.map((f) => f.kind), [ViDataType.boolean, ViDataType.i32]);
    expect(fields[1].label, 'handle');
    expect(clusterFields(pool[0], pool.types), isEmpty);
    expect(
      () => decodeTypePool(
        poolOf([
          descriptor(TypeCode.cluster, [3, 0xe7]),
        ]),
      ),
      throwsA(isA<AssertionError>()),
      reason: 'a member count that overruns the descriptor',
    );
  });

  test('arrays: dimension sizes and the element index; typeLabel spells array<element>', () {
    final oneD = decodeTypePool(
      poolOf([
        numeric(TypeCode.dbl),
        descriptor(TypeCode.array, [0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0]),
      ]),
    );
    final a = oneD[1] as ViArrayType;
    expect((a.dimCount, a.dimSizeAt(0), a.elementIndex), (1, 0xffffffff, 0));
    expect(typeLabel(a, oneD.types), 'array<dbl>');
    expect(typeLabel(oneD[0], oneD.types), 'dbl');
    final twoD = decodeTypePool(
      poolOf([
        numeric(TypeCode.dbl),
        descriptor(TypeCode.array, [0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0], name: 'grid'),
      ]),
    );
    final g = twoD[1] as ViArrayType;
    expect((g.dimCount, g.dimSizeAt(1), g.elementIndex, g.label), (2, 4, 0, 'grid'));
  });

  test('enums: Pascal items padded to an even length, then a property byte', () {
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.enumU16, [0, 2, ...'Rising'.codeUnits, ...'Falling'.codeUnits, 0, 0], name: 'Edge'),
        descriptor(TypeCode.enumU8, [0, 2, ...'FP'.codeUnits, ...'BD'.codeUnits, 0]),
      ]),
    );
    final e = pool[0] as ViEnumType;
    expect((e.itemCount, e.label, e.property), (2, 'Edge', 0));
    expect(e.items, ['Rising', 'Falling']);
    expect((pool[1] as ViEnumType).items, ['FP', 'BD']);
  });

  test('typedefs: id, path components and the inline base to the end; the base carries the label', () {
    List<int> base(List<int> d) => [...d]..[1] += 4;
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.boolean, []),
        numeric(TypeCode.i32),
        descriptor(TypeCode.typeDef, [
          0, 0, 0, 7, 0, 0, 0, 2, //
          ...'Lib'.codeUnits, ...'Y.ctl'.codeUnits,
          ...base(descriptor(TypeCode.cluster, [0, 2, 0, 0, 0, 1], name: 'Pair')),
        ]),
      ]),
    );
    final t = pool[2] as ViTypedefType;
    expect((t.id, t.componentCount, t.componentAt(1), t.hasLabel, t.label), (7, 2, 'Y.ctl', false, 'Pair'));
    final b = t.base as ViClusterType;
    expect(b.memberIndices, [0, 1]);
    expect(b.declaredLength - b.length, 4);
    expect(clusterFields(b, pool.types).map((f) => f.kind), [ViDataType.boolean, ViDataType.i32]);
    expect(serializedDefaultSize(t, pool.types), 5);
  });

  test('retained bodies: refnum kind, function parameters, and the rest as undecoded bytes', () {
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.refnum, [0, 8, 0, 0, 0, 2, 0, 0], name: 'This VI'),
        descriptor(TypeCode.function, [0, 2, 0, 0, 0, 0, 9, 9, 9, 9]),
        descriptor(TypeCode.tag, [0xff, 0xff, 0xff, 0xff, 0, 4, 5, 6]),
      ]),
    );
    final r = pool[0] as ViRefnumType;
    expect((r.refKind, r.label), (8, 'This VI'));
    expect(r.undecoded, [0, 0, 0, 2, 0, 0]);
    final f = pool[1] as ViFunctionType;
    expect((f.parameterCount, f.parameterIndexAt(1)), (2, 0));
    expect(f.undecoded, [9, 9, 9, 9]);
    final g = pool[2] as ViTagType;
    expect(g.tagKind, 4);
    expect(g.undecoded, [5, 6]);
  });

  test('serializedDefaultSize: fixed-width leaves, cluster is the member sum, variable/unknown are null', () {
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.voidType, []),
        numeric(TypeCode.i8),
        numeric(TypeCode.i16),
        numeric(TypeCode.i32),
        numeric(TypeCode.i64),
        numeric(TypeCode.dbl),
        numeric(TypeCode.ext),
        numeric(TypeCode.complexExt),
        descriptor(TypeCode.enumU8, [0, 0, 0]),
        descriptor(TypeCode.enumU16, [0, 0, 0]),
        descriptor(TypeCode.enumU32, [0, 0, 0]),
        descriptor(TypeCode.boolean, []),
        descriptor(TypeCode.refnum, [0, 8]),
        descriptor(TypeCode.string, [0xff, 0xff, 0xff, 0xff]),
        descriptor(TypeCode.array, [0, 1, 0xff, 0xff, 0xff, 0xff, 0, 3]),
        descriptor(TypeCode.variant, []),
        descriptor(TypeCode.ptr, []),
        descriptor(TypeCode.cluster, [0, 3, 0, 11, 0, 3, 0, 5]),
        descriptor(TypeCode.cluster, [0, 1, 0, 13]),
      ]),
    );
    int? sz(int i) => serializedDefaultSize(pool[i], pool.types);
    expect([for (var i = 0; i < 13; i++) sz(i)], [0, 1, 2, 4, 8, 8, 16, 32, 1, 2, 4, 1, 4]);
    expect([for (var i = 13; i < 17; i++) sz(i)], [null, null, null, null]);
    expect((sz(17), sz(18)), (13, null));
  });

  test('the top-level list follows the descriptors and must tile the payload', () {
    final pool = decodeTypePool(
      poolOf(
        [
          descriptor(TypeCode.string, [0xff, 0xff, 0xff, 0xff]),
          descriptor(TypeCode.boolean, []),
        ],
        topLevel: [1, 0, 1],
      ),
    );
    expect((pool.topLevelCount, pool.topLevelIndexAt(2)), (3, 1));
    expect(pool.topLevelIndices, [1, 0, 1]);
    expect(() => decodeTypePool(u8([0, 0, 0, 1, 0, 4, 0, 0x30, 0, 1])), throwsA(isA<AssertionError>()));
    expect(() => decodeTypePool(u8([0, 0, 0, 5])), throwsA(isA<AssertionError>()));
    expect(() => decodeTypePool(Uint8List(0)), throwsA(isA<AssertionError>()));
  });

  test('typeKindHistogram counts kinds, most-frequent first', () {
    final pool = decodeTypePool(
      poolOf([
        descriptor(TypeCode.cluster, [0, 0]),
        descriptor(TypeCode.cluster, [0, 0]),
        descriptor(TypeCode.string, [0xff, 0xff, 0xff, 0xff]),
        descriptor(TypeCode.cluster, [0, 0]),
        descriptor(TypeCode.boolean, []),
      ]),
    );
    final h = typeKindHistogram(pool.types);
    expect((h['cluster'], h['string'], h['boolean'], h.keys.first), (3, 1, 1, 'cluster'));
  });

  test('decodeTypeMap (TM80): word list, or inline descriptors and entries behind a zero word', () {
    final indexed = decodeTypeMap(hx('0003 0004 8000d000 2000 8000d001')) as ViTypeMapIndexed;
    expect((indexed.count, indexed.indexShift), (3, 4));
    expect([for (var i = 0; i < 3; i++) indexed.flagsAt(i)], [0xd000, 0x2000, 0xd001]);
    expect(indexed.serialize(), same(indexed.bytes));
    final inline = decodeTypeMap(
      u8([
        0,
        0,
        0,
        2,
        ...descriptor(TypeCode.boolean, [], name: 'Boolean'),
        ...descriptor(TypeCode.u32, [], name: 'flg'),
        ...hx('0003 0000 1000 0001 2000 0001 80080000'),
      ]),
    );
    expect(inline, isA<ViTypeMapInline>());
    expect((inline as ViTypeMapInline).types.map((t) => t.label), ['Boolean', 'flg']);
    expect(
      [for (var i = 0; i < inline.count; i++) (inline.typeIndexAt(i), inline.flagsAt(i))],
      [
        (0, 0x1000),
        (1, 0x2000),
        (1, 0x80000),
      ],
    );
    expect(() => decodeTypeMap(hx('0003 0004 8000')), throwsA(isA<AssertionError>()));
    expect(
      () => decodeTypeMap(u8([0, 0, 0, 1, ...descriptor(TypeCode.boolean, []), ...hx('0001 0002 0000')])),
      throwsA(isA<AssertionError>()),
    );
    expect(() => decodeTypeMap(hx('00')), throwsA(isA<AssertionError>()));
  });

  test('decodeDataTypeHeap (DTHP): two words, one word, inline descriptors and entries, or a retained body', () {
    final compact = decodeDataTypeHeap(hx('00170004')) as ViDataTypeHeapCompact;
    expect((compact.heapTypeCount, compact.firstTopLevelIndex, compact.viTypeIndexBase), (0x17, 4, 2));
    expect((decodeDataTypeHeap(hx('0000')) as ViDataTypeHeapWord).word, 0);
    final inline =
        decodeDataTypeHeap(
              u8([0, 0, 0, 1, ...descriptor(TypeCode.boolean, [], name: 'Auto Stop'), ...hx('0002 0000 0000')]),
            )
            as ViDataTypeHeapInline;
    expect(inline.types.single.label, 'Auto Stop');
    expect([for (var i = 0; i < inline.count; i++) inline.typeIndexAt(i)], [0, 0]);
    expect(
      decodeDataTypeHeap(u8([0, 0, 0, 1, ...descriptor(TypeCode.boolean, [])])),
      isA<ViDataTypeHeapRetained>(),
    );
    expect(decodeDataTypeHeap(u8([0, 0, 0, 0, ...'DTHP'.codeUnits, 0, 0, 0, 0x44])), isA<ViDataTypeHeapRetained>());
    expect(() => decodeDataTypeHeap(hx('00')), throwsA(isA<AssertionError>()));
  });
}
