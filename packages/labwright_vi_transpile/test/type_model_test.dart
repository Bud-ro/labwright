import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show PrimOp;
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'pool_builder.dart';

void main() {
  test('numeric widths: carrier, renormalizing expression, storage list', () {
    // (kind, carrier, wrap('a + b'), typed list)
    const rows = <(LvNumericKind, String, String, String)>[
      (LvNumericKind.u8, 'int', '(a + b) & 0xFF', 'Uint8List'),
      (LvNumericKind.u16, 'int', '(a + b) & 0xFFFF', 'Uint16List'),
      (LvNumericKind.u32, 'int', '(a + b) & 0xFFFFFFFF', 'Uint32List'),
      (LvNumericKind.u64, 'int', 'a + b', 'Uint64List'),
      (LvNumericKind.i8, 'int', '(a + b) << 56 >> 56', 'Int8List'),
      (LvNumericKind.i16, 'int', '(a + b) << 48 >> 48', 'Int16List'),
      (LvNumericKind.i32, 'int', '(a + b) << 32 >> 32', 'Int32List'),
      (LvNumericKind.i64, 'int', 'a + b', 'Int64List'),
      (LvNumericKind.sgl, 'double', '(Float32List(1)..[0] = a + b)[0]', 'Float32List'),
      (LvNumericKind.dbl, 'double', 'a + b', 'Float64List'),
    ];
    for (final (kind, carrier, wrapped, list) in rows) {
      expect(
        (kind.dartType, kind.wrap('a + b'), kind.typedListType, LvNumericKind.ofCode(kind.code)),
        (carrier, wrapped, list, kind),
        reason: kind.glyph,
      );
    }
    // The wrap expressions must actually hold on the carrier.
    expect(0xFFFFFFFF + 1 & 0xFFFFFFFF, 0, reason: 'U32 addition truncates at 32 bits');
    expect(0xFF << 56 >> 56, -1, reason: 'I8 0xFF sign-extends to -1');

    // Only the kinds that cannot renormalize carry hazards.
    expect(
      {for (final kind in LvNumericKind.values) kind: kind.hazards.length},
      {
        for (final kind in LvNumericKind.values)
          kind: switch (kind) {
            LvNumericKind.u64 => 4,
            LvNumericKind.sgl => 1,
            _ => 0,
          },
      },
    );
    expect(LvNumericKind.u64.hazards.expand((h) => h.operators), containsAll(['<', '~/', '>>', 'toString']));
    expect(LvNumericKind.u64.needsWrap, isFalse, reason: 'a U64 already fills the 64-bit carrier');
    expect(LvNumericKind.u32.maskLiteral, '0xFFFFFFFF');
    expect(LvNumericKind.i32.maskLiteral, isNull, reason: 'signed kinds sign-extend, they do not mask');
  });

  test('leaf types map to their Dart carriers; review-list codes stay unmapped', () {
    // (descriptor, expected Dart type or null when the code is on the review list)
    final rows = <(List<int>, String?)>[
      (scalar(TypeCode.voidType), 'void'),
      (scalar(TypeCode.boolean), 'bool'),
      (scalar(TypeCode.u32), 'int'),
      (scalar(TypeCode.dbl), 'double'),
      (scalar(TypeCode.string), 'String'),
      (scalar(TypeCode.cString), 'String'),
      (scalar(TypeCode.path), LvRuntimeType.path),
      (scalar(TypeCode.refnum), LvRuntimeType.refnum),
      (scalar(TypeCode.variant), LvRuntimeType.variant),
      (scalar(TypeCode.ext), null),
      (scalar(TypeCode.complexDbl), null),
      (scalar(TypeCode.picture), null),
      (scalar(TypeCode.subArray), null),
      (scalar(TypeCode.measureData), null),
      (scalar(0x73), null),
    ];
    for (final (descriptor, expected) in rows) {
      final type = poolOf([descriptor]).single;
      final mapping = mapLvType(type, poolOf([descriptor]));
      expect(
        (mapping.status, mapping.dartType),
        (expected == null ? LvMapStatus.unmapped : LvMapStatus.mapped, expected),
        reason: '0x${type.code.toRadixString(16)}',
      );
      if (expected == null) expect(mapping.note, isNotNull, reason: 'every unmapped entry states why');
    }
    // Descriptors that are not dataflow values are their own bucket.
    for (final code in [TypeCode.function, TypeCode.ptr, TypeCode.repeatedBlock, TypeCode.alignmentMarker]) {
      expect(mapLvType(poolOf([scalar(code)]).single, const []).status, LvMapStatus.internal);
    }
    expect(kUnmappedTypeCodes.keys.every(lvTypeCodeIsAccountedFor), isTrue);
  });

  test('arrays: exact-width storage per element, flat N-D, builder grows then freezes', () {
    // (element code, dims, Dart type)
    const rows = <(int, int, String)>[
      (TypeCode.u8, 1, 'Uint8List'),
      (TypeCode.i32, 1, 'Int32List'),
      (TypeCode.u64, 1, 'Uint64List'),
      (TypeCode.sgl, 1, 'Float32List'),
      (TypeCode.boolean, 1, 'List<bool>'),
      (TypeCode.string, 1, 'List<String>'),
      (TypeCode.path, 1, 'List<LvPath>'),
      (TypeCode.refnum, 1, 'List<LvRefnum>'),
      (TypeCode.i32, 2, 'LvArrayNd<Int32List>'),
      (TypeCode.u64, 3, 'LvArrayNd<Uint64List>'),
      (TypeCode.string, 2, 'LvArrayNd<List<String>>'),
    ];
    for (final (element, dims, expected) in rows) {
      final types = poolOf([scalar(element), array(0, dims)]);
      expect(mapLvType(types[1], types).dartType, expected, reason: '${dims}D of 0x${element.toRadixString(16)}');
    }
    // An unmapped element leaves the whole array unmapped, with the reason.
    final ext = poolOf([scalar(TypeCode.ext), array(0, 1)]);
    expect(mapLvType(ext[1], ext).status, LvMapStatus.unmapped);
    expect(mapLvType(ext[1], ext).note, contains('80-bit'));

    // Growth: append into a growable list, convert once at the boundary.
    const u8Element = LvTypeMapping.mapped('int', numeric: LvNumericKind.u8);
    const stringElement = LvTypeMapping.mapped('String');
    expect(lvArrayBuilderType(u8Element), 'List<int>');
    expect(lvArrayFreeze(u8Element, 'acc'), 'Uint8List.fromList(acc)');
    expect(lvArrayFreeze(stringElement, 'acc'), 'acc', reason: 'a List<T> storage needs no conversion');
  });

  test('clusters: named ones are nominal, anonymous ones are records', () {
    final named = poolOf([
      scalar(TypeCode.boolean),
      scalar(TypeCode.i32),
      cluster([0, 1], name: 'Motor State'),
    ]);
    expect(mapLvType(named[2], named).dartType, 'MotorState');

    // Anonymous + every member named and distinct → a named record.
    final rec = poolOf([
      scalar(TypeCode.dbl, name: 'volts'),
      scalar(TypeCode.string, name: 'Serial Number'),
      cluster([0, 1]),
    ]);
    expect(mapLvType(rec[2], rec).dartType, '({double volts, String serialNumber})');

    // Anonymous with unnamed or colliding members → a positional record.
    final positional = poolOf([
      scalar(TypeCode.dbl),
      scalar(TypeCode.i32),
      cluster([0, 1]),
    ]);
    expect(mapLvType(positional[2], positional).dartType, '(double, int)');
    final collide = poolOf([
      scalar(TypeCode.dbl, name: 'a'),
      scalar(TypeCode.i32, name: 'A'),
      cluster([0, 1]),
    ]);
    expect(mapLvType(collide[2], collide).dartType, '(double, int)');

    // A member with no representation makes the cluster unmapped, not a guess.
    final withExt = poolOf([
      scalar(TypeCode.ext),
      cluster([0], name: 'Reading'),
    ]);
    expect(mapLvType(withExt[1], withExt).status, LvMapStatus.unmapped);
  });

  test('typedefs are nominal over a cluster or enum, transparent over a scalar', () {
    // (base descriptor, typedef name, Dart type)
    final rows = <(List<int>, String, String)>[
      ([0x40, TypeCode.u64], 'Tick Count', 'int'),
      ([0x40, TypeCode.string], 'Device Name', 'String'),
      ([0x40, TypeCode.cluster, 0, 0], 'WPI_PWMDeadband.ctl', 'WpiPwmdeadbandCtl'),
      ([0x40, TypeCode.enumU16, 0, 1, ...pascal('PWM')], 'Motor Type', 'MotorType'),
    ];
    for (final (baseBody, name, expected) in rows) {
      final types = poolOf([typeDef(baseBody, name)]);
      expect(mapLvType(types.single, types).dartType, expected, reason: name);
      expect(types.single.typedefBase, isNotNull);
    }
    // No inline base recovered → unmapped, never assumed.
    final bare = poolOf([scalar(TypeCode.typeDef)]);
    expect(mapLvType(bare.single, bare).status, LvMapStatus.unmapped);
  });

  test('error clusters need both the member types and the member names', () {
    // (member codes, member names, is an error cluster) — rows drawn from the
    // corpus census of {boolean, integer, string} clusters.
    final rows = <(List<int>, List<String?>, bool)>[
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], ['status', 'code', 'source'], true),
      ([TypeCode.boolean, TypeCode.u32, TypeCode.string], ['status', 'code', 'source'], true),
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], ['Status', 'Code', 'Source'], true),
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], [null, null, null], false),
      ([TypeCode.boolean, TypeCode.boolean, TypeCode.boolean], ['status', 'code', 'source'], false),
      ([TypeCode.boolean, TypeCode.boolean, TypeCode.string], ['control', 'shift', 'key'], false),
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], ['status', 'code'], false),
    ];
    for (final (codes, names, expected) in rows) {
      final types = poolOf([
        for (var i = 0; i < codes.length; i++) scalar(codes[i], name: i < names.length ? names[i] : null),
        cluster([for (var i = 0; i < codes.length; i++) i], name: 'error out'),
      ]);
      final subject = types.last;
      expect(isLvErrorCluster(subject, types), expected, reason: '$codes $names');
      expect(mapLvType(subject, types).dartType, expected ? LvRuntimeType.error : 'ErrorOut');
    }
  });

  test('error mode decides the signature: elided and thrown, or threaded through', () {
    const dbl = LvTypeMapping.mapped('double');
    const err = LvTypeMapping.mapped(LvRuntimeType.error);
    const terminals = [
      LvTerminal('error in (no error)', err, isErrorCluster: true),
      LvTerminal('Message String', dbl),
      LvTerminal('error out', err, isErrorCluster: true),
    ];
    final thrown = lvSignature(terminals, LvErrorMode.exceptions);
    expect(thrown.carried.map((t) => t.name), ['Message String']);
    expect((thrown.throwsLvError, thrown.elided.length), (true, 2));

    final threaded = lvSignature(terminals, LvErrorMode.threaded);
    expect(threaded.carried.length, 3);
    expect(threaded.throwsLvError, isFalse);
    expect(threaded.elided, isEmpty);

    // A VI with no error cluster reads the same either way.
    const plain = [LvTerminal('bytes', dbl)];
    for (final mode in LvErrorMode.values) {
      expect(lvSignature(plain, mode).throwsLvError, isFalse);
    }

    // The value an elided `error in` starts from, and an elided `error out`
    // reads back, is the runtime's own cleared cluster.
    expect(LvRuntimeType.clearedError, '${LvRuntimeType.error}.none');
    expect(lvTypeNeedsRuntime(LvRuntimeType.clearedError), isTrue);
  });

  test('only a bare error cluster is the wire an error mode acts on', () {
    // (member codes, array dimensions, is the error wire) — an array of error
    // clusters is ordinary data and keeps its place in every signature.
    final rows = <(List<int>, int, bool)>[
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], 0, true),
      ([TypeCode.boolean, TypeCode.i32, TypeCode.string], 1, false),
      ([TypeCode.boolean, TypeCode.i32, TypeCode.i32], 0, false),
    ];
    for (final (codes, dims, expected) in rows) {
      final types = poolOf([
        for (var i = 0; i < codes.length; i++) scalar(codes[i], name: const ['status', 'code', 'source'][i]),
        cluster([0, 1, 2], name: 'error out'),
      ]);
      final signal = ViSignalType(TypeCode.cluster | (3 + dims) << 8);
      final wire = lvClusterWireType(signal, types.last, types);
      expect(wire.isErrorCluster, expected, reason: '$codes ${dims}D');
    }
  });

  test('connector-pane terminals resolve through the pool; a non-cluster pane yields none', () {
    final types = poolOf([
      scalar(TypeCode.boolean, name: 'status'),
      scalar(TypeCode.i32, name: 'code'),
      scalar(TypeCode.string, name: 'source'),
      cluster([0, 1, 2], name: 'error out'),
      scalar(TypeCode.u32, name: 'CRC-32'),
      cluster([3, 4]),
    ]);
    final terminals = lvTerminals(types, 6);
    expect(terminals.map((t) => (t.name, t.type.dartType, t.isErrorCluster)), [
      ('error out', LvRuntimeType.error, true),
      ('CRC-32', 'int', false),
    ]);
    expect(lvTerminals(types, 5), isEmpty, reason: 'a non-cluster connector pane resolves to no terminals');
    expect(lvTerminals(types, null), isEmpty);
    expect(lvTerminals(types, 99), isEmpty);
  });

  test('identifier sanitizing: type names, field names, reserved words', () {
    const rows = <(String, String, String)>[
      ('error out', 'ErrorOut', 'errorOut'),
      ('WPI_PWMDeadband.ctl', 'WpiPwmdeadbandCtl', 'wpiPwmdeadbandCtl'),
      ('8-bits', 'Lv8Bits', 'lv8Bits'),
      ('class', 'Class', r'class$'),
      ('', '', ''),
      ('  ', '', ''),
    ];
    for (final (raw, className, fieldName) in rows) {
      expect((lvClassName(raw), lvFieldName(raw)), (className, fieldName), reason: raw);
    }
  });

  test('wire type words: element carrier, dimensionality, whole-wire type', () {
    // (raw signal word, dims, whole-wire Dart type or null when unmapped) —
    // words read off crc8.vi's own signals and the families beside them.
    const rows = <(int, int, String?)>[
      (0x0105, 0, 'int'), // U8 scalar
      (0x4105, 0, 'int'), // the same, other flag nibble
      (0x0205, 1, 'Uint8List'), // array of U8
      (0x0305, 2, 'LvArrayNd<Uint8List>'), // 2-D array of U8
      (0x0103, 0, 'int'), // I32 scalar
      (0x0107, 0, 'int'), // U32 scalar
      (0x0121, 0, 'bool'),
      (0x0221, 1, 'List<bool>'),
      (0x0230, 0, 'String'),
      (0x010a, 0, 'double'), // DBL
      (0x0150, 0, null), // cluster: members are not on the wire
      (0x0132, 0, null), // path: no declared runtime carrier
      (0x0153, 0, null), // variant
    ];
    for (final (raw, dims, dartType) in rows) {
      final wire = mapLvWireType(ViSignalType(raw));
      expect(
        (wire.dims, wire.dartType),
        (dims, dartType),
        reason: '0x${raw.toRadixString(16)}: ${wire.value.note}',
      );
    }
  });

  test('the operand-order-free primitives lower; a hazardous carrier refuses', () {
    // (op, input signal words, output word, statement or null when refused).
    // Signal words: 0x0105 U8 scalar, 0x0107 U32, 0x0108 U64, 0x010a DBL,
    // 0x0121 boolean, 0x0230 string, 0x0205 array of U8.
    const rows = <(PrimOp, List<int>, int, String?)>[
      (PrimOp.equal, [0x0105, 0x0105], 0x0121, 'final bool e0 = a0 == a1;'),
      (PrimOp.notEqual, [0x0230, 0x0230], 0x0121, 'final bool e0 = a0 != a1;'),
      // A U64's carrier is signed, so ordered comparisons on it are wrong —
      // but equality reads the same bits either way.
      (PrimOp.equal, [0x0108, 0x0108], 0x0121, 'final bool e0 = a0 == a1;'),
      (PrimOp.greaterThanZero, [0x0108], 0x0121, null),
      (PrimOp.lessThanZero, [0x0107], 0x0121, 'final bool e0 = a0 < 0;'),
      (PrimOp.greaterOrEqualToZero, [0x0105], 0x0121, 'final bool e0 = a0 >= 0;'),
      (PrimOp.lessOrEqualToZero, [0x010a], 0x0121, 'final bool e0 = a0 <= 0.0;'),
      (PrimOp.equalToZero, [0x0105], 0x0121, 'final bool e0 = a0 == 0;'),
      (PrimOp.notEqualToZero, [0x0108], 0x0121, 'final bool e0 = a0 != 0;'),
      (PrimOp.emptyStringPath, [0x0230], 0x0121, 'final bool e0 = a0.isEmpty;'),
      (PrimOp.stringLength, [0x0230], 0x0103, 'final int e0 = a0.length;'),
      (PrimOp.arraySize, [0x0205], 0x0103, 'final int e0 = a0.length;'),
      // Shapes the rules do not cover: the elementwise comparison, a path
      // operand (whose emptiness test is not the string one), and the
      // higher-rank Array Size that yields a vector of sizes.
      (PrimOp.equal, [0x0205, 0x0205], 0x0221, null),
      // A path carrier defines no `==`, so Dart would compare identities.
      (PrimOp.equal, [0x0132, 0x0132], 0x0121, null),
      (PrimOp.emptyStringPath, [0x0132], 0x0121, null),
      (PrimOp.arraySize, [0x0305], 0x0203, null),
    ];
    for (final (op, inputs, output, expected) in rows) {
      final call = LvPrimCall(
        op: op,
        classCode: 0x2f,
        inputs: [
          for (var at = 0; at < inputs.length; at++)
            LvPrimTerminal(port: at, type: mapLvWireType(ViSignalType(inputs[at])), roleFlags: 0, expression: 'a$at'),
        ],
        outputs: [
          LvPrimTerminal(port: 9, type: mapLvWireType(ViSignalType(output)), roleFlags: 0, expression: 'e0'),
        ],
        requireImport: (_) {},
      );
      expect(lvPrimLowering(call), expected == null ? null : [expected], reason: op.opName);
    }
  });

  test('Index Array lowers a rank-1 group per output and refuses the rest', () {
    // (name, input roles, output roles, statements or null when refused).
    // Roles are read off the corpus shapes in LvArrayTerminalRole; the array
    // wire is 1-D U8 and every index and element is a U8 scalar, so only the
    // roles decide the outcome.
    const array = LvArrayTerminalRole.array;
    const index = LvArrayTerminalRole.singleIndex;
    const first = LvArrayTerminalRole.groupFirst;
    const last = LvArrayTerminalRole.groupLast;
    const out = LvArrayTerminalRole.output;
    const grown = LvArrayTerminalRole.grownOutput;
    final rows = <(String, List<int>, List<int>, List<String>?)>[
      ('one group', [array, index], [out], ['final int e0 = a0[a1];']),
      ('two groups', [array, index, index], [out, grown], ['final int e0 = a0[a1];', 'final int e1 = a0[a2];']),
      (
        'four groups',
        [array, index, index, index, index],
        [out, grown, grown, grown],
        [
          'final int e0 = a0[a1];',
          'final int e1 = a0[a2];',
          'final int e2 = a0[a3];',
          'final int e3 = a0[a4];',
        ],
      ),
      // A rank-2 group: the dimension order is not decoded.
      ('rank 2', [array, first, last], [out], null),
      ('rank 2, first index only', [array, first], [out], null),
      ('rank 2, last index only', [array, last], [out], null),
      // Shapes that do not read as the grammar at all.
      ('no array terminal', [index, index], [out], null),
      ('index without an output', [array, index, index], [out], null),
      ('grown output first', [array, index], [grown], null),
    ];
    for (final (name, inputRoles, outputRoles, expected) in rows) {
      LvPrimTerminal terminal(int role, int at, {required bool isInput}) => LvPrimTerminal(
        port: at,
        type: mapLvWireType(ViSignalType(role == LvArrayTerminalRole.array ? 0x0205 : 0x0105)),
        roleFlags: role,
        expression: isInput ? 'a$at' : 'e$at',
      );
      final call = LvPrimCall(
        op: null,
        classCode: kLvIndexArrayClass,
        inputs: [for (var at = 0; at < inputRoles.length; at++) terminal(inputRoles[at], at, isInput: true)],
        outputs: [for (var at = 0; at < outputRoles.length; at++) terminal(outputRoles[at], at, isInput: false)],
        requireImport: (_) {},
      );
      expect(lvPrimLowering(call), expected, reason: name);
    }
  });

  test('Float32List narrowing is what SGL arithmetic needs', () {
    // 0.1 + 0.2 at binary32 differs from the binary64 result LabVIEW would not
    // produce for a SGL wire.
    const sum = 0.1 + 0.2;
    final narrowed = (Float32List(1)..[0] = sum)[0];
    expect(narrowed, isNot(sum));
    expect(narrowed, (Float32List(1)..[0] = 0.30000001192092896)[0]);
  });
}
