import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show PrimOp;
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'pool_builder.dart';
import 'snippets.dart';

void main() {
  test('numeric widths: carrier, renormalizing expression, storage list', () {
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
    for (final (kind, dartType, wrapped, list) in rows) {
      expect(
        (kind.carrier.dartType, kind.wrap('a + b'), kind.typedListType, LvNumericKind.ofCode(kind.code)),
        (dartType, wrapped, list, kind),
        reason: kind.glyph,
      );
    }
    expect(0xFFFFFFFF + 1 & 0xFFFFFFFF, 0, reason: 'U32 addition truncates at 32 bits');
    expect(0xFF << 56 >> 56, -1, reason: 'I8 0xFF sign-extends to -1');

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
    for (final code in [TypeCode.function, TypeCode.ptr, TypeCode.repeatedBlock, TypeCode.alignmentMarker]) {
      expect(mapLvType(poolOf([scalar(code)]).single, const []).status, LvMapStatus.internal);
    }
    expect(kUnmappedTypeCodes.keys.every(lvTypeCodeIsAccountedFor), isTrue);
  });

  test('arrays: exact-width storage per element, flat N-D, builder grows then freezes', () {
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
    final ext = poolOf([scalar(TypeCode.ext), array(0, 1)]);
    expect(mapLvType(ext[1], ext).status, LvMapStatus.unmapped);
    expect(mapLvType(ext[1], ext).note, contains('80-bit'));

    const u8Element = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.u8);
    const stringElement = LvTypeMapping.mapped(LvCarrier.text);
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

    final rec = poolOf([
      scalar(TypeCode.dbl, name: 'volts'),
      scalar(TypeCode.string, name: 'Serial Number'),
      cluster([0, 1]),
    ]);
    expect(mapLvType(rec[2], rec).dartType, '({double volts, String serialNumber})');

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

    final withExt = poolOf([
      scalar(TypeCode.ext),
      cluster([0], name: 'Reading'),
    ]);
    expect(mapLvType(withExt[1], withExt).status, LvMapStatus.unmapped);
  });

  test('a nominal type carries the declaration a library must write for it', () {
    final types = poolOf([
      enumeration(['Off', 'On'], name: 'Mode'),
      scalar(TypeCode.dbl, name: 'volts'),
      cluster([0, 1], name: 'Channel Setting'),
    ]);
    final mapping = mapLvType(types[2], types, 0, LvDeclarations());
    expect(mapping.dartType, 'ChannelSetting');
    expect(lvDeclarationClosure(mapping.declarations).map((d) => d.name), ['Mode', 'ChannelSetting']);
    expect(lvDeclarationSource(lvDeclarationClosure(mapping.declarations).first), '''
/// The LabVIEW enum `Mode`. A member's `index` is the
/// value the wire carries: the descriptor states the item labels in order
/// and no value of its own for any of them.
enum Mode {
/// `Off`
off,
/// `On`
on
}
''');
    expect(lvDeclarationSource(mapping.declarations.single), '''
/// The LabVIEW cluster `Channel Setting`.
class ChannelSetting {
const ChannelSetting({required this.mode, required this.volts});

/// `Mode`
final Mode mode;

final double volts;
}
''');
  });

  test('declaration naming: unnamed, inherited and colliding members all resolve', () {
    const rows = <(List<String?>, List<String>)>[
      ([null, 'volts'], ['member', 'volts']),
      (['a', 'A'], ['a', 'a2']),
      (['hashCode', 'index'], ['hashCode2', 'index2']),
      (['class', 'volts'], [r'$class', 'volts']),
      (['8-bits'], ['lv8Bits']),
    ];
    for (final (labels, expected) in rows) {
      expect(LvNaming.declarationFields(labels), expected, reason: '$labels');
    }
  });

  test('declarations are keyed by structure, and a name is only the preferred spelling', () {
    List<ViType> named(int code, String label) => poolOf([
      scalar(code, name: 'x'),
      cluster([0], name: label),
    ]);
    final registry = LvDeclarations();
    final first = named(TypeCode.dbl, 'Reading');
    final again = named(TypeCode.dbl, 'Reading');
    final other = named(TypeCode.i32, 'Reading');
    expect(mapLvType(first[1], first, 0, registry).dartType, 'Reading');
    expect(mapLvType(again[1], again, 0, registry).dartType, 'Reading');
    expect(mapLvType(other[1], other, 0, registry).dartType, 'Reading2');
    expect(registry.all.length, 2);
    final shadow = named(TypeCode.dbl, 'String');
    expect(mapLvType(shadow[1], shadow, 0, registry).dartType, 'String2');
    expect(kLvReservedTypeNames, containsAll(<String>['String', 'Uint8List', LvRuntimeType.error]));

    final blank = poolOf([enumeration(const [], name: 'Mode')]);
    final mapping = mapLvType(blank.single, blank, 0, LvDeclarations());
    expect(mapping.declarations.single.undeclarable, isNotNull);
    expect(mapping.declarations.single.items, isEmpty);
  });

  test('typedefs are nominal over a cluster or enum, transparent over a scalar', () {
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
    final bare = poolOf([scalar(TypeCode.typeDef)]);
    expect(mapLvType(bare.single, bare).status, LvMapStatus.unmapped);
  });

  test('error clusters need both the member types and the member names', () {
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
    const dbl = LvTypeMapping.mapped(LvCarrier.float);
    const err = LvTypeMapping.mapped(LvCarrier.error);
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

    const plain = [LvTerminal('bytes', dbl)];
    for (final mode in LvErrorMode.values) {
      expect(lvSignature(plain, mode).throwsLvError, isFalse);
    }

    expect(LvRuntimeType.clearedError, '${LvRuntimeType.error}.none');
    expect(lvTypeNeedsRuntime(err), isTrue);
  });

  test('both imports follow the carrier, not the spelling', () {
    final rows = <(List<List<int>>, String, bool, bool)>[
      ([scalar(TypeCode.boolean)], 'bool', false, false),
      ([scalar(TypeCode.path)], 'LvPath', true, false),
      ([scalar(TypeCode.variant)], 'LvVariant', true, false),
      ([scalar(TypeCode.string), array(0, 1)], 'List<String>', false, false),
      ([scalar(TypeCode.u8), array(0, 1)], 'Uint8List', false, true),
      ([scalar(TypeCode.i32), array(0, 2)], 'LvArrayNd<Int32List>', true, true),
      ([scalar(TypeCode.path), array(0, 1)], 'List<LvPath>', true, false),
      (
        [
          scalar(TypeCode.path, name: 'where'),
          cluster([0]),
        ],
        '({LvPath where})',
        true,
        false,
      ),
      (
        [
          scalar(TypeCode.u8),
          array(0, 1),
          scalar(TypeCode.dbl, name: 'volts'),
          cluster([1, 2]),
        ],
        '(Uint8List, double)',
        false,
        true,
      ),
      (
        [
          scalar(TypeCode.dbl, name: 'volts'),
          cluster([0], name: 'LV error log'),
        ],
        'LvErrorLog',
        false,
        false,
      ),
      (
        [
          scalar(TypeCode.dbl, name: 'volts'),
          cluster([0], name: 'LV error log'),
          array(1, 1),
        ],
        'List<LvErrorLog>',
        false,
        false,
      ),
      (
        [
          scalar(TypeCode.dbl, name: 'volts'),
          cluster([0], name: 'Uint8 List'),
        ],
        'Uint8List2',
        false,
        false,
      ),
      (
        [
          scalar(TypeCode.dbl, name: 'volts'),
          cluster([0], name: 'Uint8 List'),
          array(1, 1),
        ],
        'List<Uint8List2>',
        false,
        false,
      ),
    ];
    for (final (descriptors, dartType, runtime, typedData) in rows) {
      final pool = poolOf(descriptors);
      final mapping = mapLvType(pool.last, pool);
      expect(
        (mapping.dartType, lvTypeNeedsRuntime(mapping), lvTypeNeedsTypedData(mapping)),
        (
          dartType,
          runtime,
          typedData,
        ),
      );
    }
  });

  test('only a bare error cluster is the wire an error mode acts on', () {
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
      ('class', 'Class', r'$class'),
      ('', '', ''),
      ('  ', '', ''),
    ];
    for (final (raw, className, fieldName) in rows) {
      expect((lvClassName(raw), lvFieldName(raw)), (className, fieldName), reason: raw);
    }
  });

  test('wire type words: element carrier, dimensionality, whole-wire type', () {
    const rows = <(int, int, String?)>[
      (0x0105, 0, 'int'),
      (0x4105, 0, 'int'),
      (0x0205, 1, 'Uint8List'),
      (0x0305, 2, 'LvArrayNd<Uint8List>'),
      (0x0103, 0, 'int'),
      (0x0107, 0, 'int'),
      (0x0121, 0, 'bool'),
      (0x0221, 1, 'List<bool>'),
      (0x0230, 0, 'String'),
      (0x010a, 0, 'double'),
      (0x0150, 0, null),
      (0x0132, 0, null),
      (0x0153, 0, null),
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

  test('a refnum wire takes its array wrapping from the dimensionality it is given', () {
    const rows = <(int, int, String)>[
      (0x0270, 0, LvRuntimeType.refnum),
      (0x0270, 1, 'List<${LvRuntimeType.refnum}>'),
      (0x0371, 0, LvRuntimeType.refnum),
      (0x0571, 1, 'List<${LvRuntimeType.refnum}>'),
      (0x0470, 2, 'LvArrayNd<List<${LvRuntimeType.refnum}>>'),
    ];
    for (final (raw, dims, dartType) in rows) {
      final wire = lvRefnumWireType(ViSignalType(raw), dims);
      expect((wire.dims, wire.dartType), (dims, dartType), reason: '0x${raw.toRadixString(16)} at $dims dims');
    }
  });

  test('a refnum wire the signal word leaves open takes its dimensionality from the endpoint parts', () {
    const rows = <String, Map<String, int>>{
      'ClassChildren': {'70_d3->0': 6, '70_d4->refused': 2},
      'Page1': {'70_d3->0': 2, '71_d5->0': 7, '71_d5->refused': 4},
      'Pages': {'70_d2->1': 10, '70_d3->0': 12, '71_d5->0': 19},
      'ProjectItems': {'70_d2->1': 2},
    };
    for (final MapEntry(key: name, value: expected) in rows.entries) {
      final diagram = snippetDiagram(name);
      final measured = <String, int>{};
      for (final wire in diagram.wires) {
        final signal = wire.signalType;
        if (signal == null || !kLvWireRefnumCodes.contains(signal.typeCode)) continue;
        if (signal.arrayDims != null) continue;
        final dims = lvRefnumWireDims(diagram, wire);
        final key = '${signal.typeCode.toRadixString(16)}_d${signal.depth}->${dims ?? 'refused'}';
        measured[key] = (measured[key] ?? 0) + 1;
      }
      expect(measured, expected, reason: name);
    }
  });

  test('a primitive lowers from its wire types, and a hazardous carrier refuses', () {
    const rows = <(PrimOp, List<int>, int, String?)>[
      (PrimOp.subtract, [0x0107, 0x0107], 0x0107, 'final int e0 = (a0 - a1) & 0xFFFFFFFF;'),
      (PrimOp.greater, [0x0105, 0x0105], 0x0121, 'final bool e0 = a0 > a1;'),
      (PrimOp.less, [0x010a, 0x010a], 0x0121, 'final bool e0 = a0 < a1;'),
      (PrimOp.greater, [0x0108, 0x0108], 0x0121, null),
      (PrimOp.less, [0x0230, 0x0230], 0x0121, null),
      (PrimOp.divide, [0x0107, 0x0107], 0x010a, 'final double e0 = a0.toDouble() / a1.toDouble();'),
      (PrimOp.divide, [0x0109, 0x0109], 0x0109, 'final double e0 = (Float32List(1)..[0] = a0 / a1)[0];'),
      (PrimOp.divide, [0x0107, 0x0107], 0x0107, null),
      (PrimOp.swapBytes, [0x0102], 0x0102, 'final int e0 = (lvSwapBytes(a0)) << 48 >> 48;'),
      (PrimOp.swapWords, [0x0107], 0x0107, 'final int e0 = (lvSwapWords(a0)) & 0xFFFFFFFF;'),
      (PrimOp.swapBytes, [0x0105], 0x0105, null),
      (PrimOp.swapWords, [0x0102], 0x0102, null),
      (PrimOp.toQuadInteger, [0x0107], 0x0104, 'final int e0 = lvToI64(a0);'),
      (PrimOp.toUnsignedQuadInteger, [0x0107], 0x0108, 'final int e0 = lvToU64(a0);'),
      (PrimOp.equal, [0x0105, 0x0105], 0x0121, 'final bool e0 = a0 == a1;'),
      (PrimOp.notEqual, [0x0230, 0x0230], 0x0121, 'final bool e0 = a0 != a1;'),
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
      (PrimOp.select, [0x0230, 0x0121, 0x0230], 0x0230, 'final String e0 = a1 ? a0 : a2;'),
      (PrimOp.select, [0x0105, 0x0105, 0x0105], 0x0105, null),
      (PrimOp.equal, [0x0132, 0x0132], 0x0121, null),
      (PrimOp.emptyStringPath, [0x0132], 0x0121, null),
      (PrimOp.arraySize, [0x0305], 0x0203, null),
      (PrimOp.waitMs, [0x0107], 0x0107, 'final int e0 = lvWaitMs(a0);'),
      (PrimOp.waitMs, [0x0103], 0x0107, 'final int e0 = lvWaitMs(a0);'),
      (PrimOp.waitMs, [0x010a], 0x0107, null),
      (PrimOp.waitMs, [0x0107], 0x0103, null),
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
        outputPorts: const [9],
        portDrawnTop: {for (var at = 0; at < inputs.length; at++) at: at},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected == null ? null : [expected], reason: op.opName);
    }
  });

  test('a wait still elapses when nothing consumes the timer it returns', () {
    List<String>? lower({required bool consumed}) => lvPrimLowering(
      LvPrimCall(
        op: PrimOp.waitMs,
        classCode: 0x2f,
        inputs: [
          LvPrimTerminal(port: 0, type: mapLvWireType(const ViSignalType(0x0107)), roleFlags: 0, expression: 'a0'),
        ],
        outputs: [
          if (consumed)
            LvPrimTerminal(port: 9, type: mapLvWireType(const ViSignalType(0x0107)), roleFlags: 0, expression: 'e0'),
        ],
        outputPorts: const [9],
        portDrawnTop: const {0: 0},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      ),
    );
    expect(lower(consumed: false), ['lvWaitMs(a0);']);
    expect(lower(consumed: true), ['final int e0 = lvWaitMs(a0);']);
  });

  test('a scalar primitive wired to arrays lowers as a map over their elements', () {
    final rows = <(String, PrimOp, List<int>, int, List<String>?)>[
      (
        'unary over one array',
        PrimOp.swapBytes,
        [0x0206],
        0x0206,
        [
          'final List<int> builder = <int>[];',
          'for (var i = 0; i < a0.length; i++) {',
          'final int value = (lvSwapBytes(a0[i])) & 0xFFFF;',
          'builder.add(value);',
          '}',
          'final Uint16List e0 = Uint16List.fromList(builder);',
        ],
      ),
      (
        'a conversion changes the element type',
        PrimOp.toUnsignedLongInteger,
        [0x0205],
        0x0207,
        [
          'final List<int> builder = <int>[];',
          'for (var i = 0; i < a0.length; i++) {',
          'final int value = lvToU32(a0[i]);',
          'builder.add(value);',
          '}',
          'final Uint32List e0 = Uint32List.fromList(builder);',
        ],
      ),
      (
        'binary over two arrays runs to the shorter',
        PrimOp.equal,
        [0x0205, 0x0205],
        0x0221,
        [
          'final List<bool> builder = <bool>[];',
          'final int count = lvIterationCount(<int>[a0.length, a1.length]);',
          'for (var i = 0; i < count; i++) {',
          'final bool flag = a0[i] == a1[i];',
          'builder.add(flag);',
          '}',
          'final List<bool> e0 = builder;',
        ],
      ),
      ('an array beside a scalar', PrimOp.multiply, [0x0205, 0x0105], 0x0205, null),
      ('rank 2', PrimOp.swapBytes, [0x0305], 0x0305, null),
      ('the scalar rule refuses', PrimOp.greater, [0x0208, 0x0208], 0x0221, null),
    ];
    for (final (name, op, inputs, output, expected) in rows) {
      final call = LvPrimCall(
        op: op,
        classCode: 0x2f,
        inputs: [
          for (var at = 0; at < inputs.length; at++)
            LvPrimTerminal(port: at, type: mapLvWireType(ViSignalType(inputs[at])), roleFlags: 0, expression: 'a$at'),
        ],
        outputs: [LvPrimTerminal(port: 9, type: mapLvWireType(ViSignalType(output)), roleFlags: 0, expression: 'e0')],
        outputPorts: const [9],
        portDrawnTop: {for (var at = 0; at < inputs.length; at++) at: at},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected, reason: name);
    }
  });

  test('a variadic node takes its operands in the order it draws them', () {
    final rows = <(String, int, List<int>, int, List<String>?)>[
      (
        'Concatenate Strings joins top-down',
        LvNodeClass.concatenateStrings.code,
        [0x0230, 0x0230, 0x0230],
        0x0230,
        [r"final String e0 = '$a0$a1$a2';"],
      ),
      ('an array operand', LvNodeClass.concatenateStrings.code, [0x0230, 0x0330], 0x0230, null),
      (
        'Build Array appends each scalar operand',
        LvNodeClass.buildArray.code,
        [0x0105, 0x0105],
        0x0205,
        ['final Uint8List e0 = Uint8List.fromList(<int>[a0, a1]);'],
      ),
      (
        'an operand level with the result is spliced in whole',
        LvNodeClass.buildArray.code,
        [0x0205, 0x0105, 0x0205],
        0x0205,
        ['final Uint8List e0 = Uint8List.fromList(<int>[...a0, a1, ...a2]);'],
      ),
      (
        'a non-numeric element keeps its List storage',
        LvNodeClass.buildArray.code,
        [0x0230, 0x0230],
        0x0330,
        ['final List<String> e0 = <String>[a0, a1];'],
      ),
      ('two dimensions below', LvNodeClass.buildArray.code, [0x0105], 0x0305, null),
      ('a rank-2 result', LvNodeClass.buildArray.code, [0x0205, 0x0205], 0x0305, null),
      ('a mismatched element', LvNodeClass.buildArray.code, [0x0105, 0x0230], 0x0205, null),
    ];
    for (final (name, classCode, inputs, output, expected) in rows) {
      final call = LvPrimCall(
        op: null,
        classCode: classCode,
        inputs: [
          for (var at = 0; at < inputs.length; at++)
            LvPrimTerminal(port: at, type: mapLvWireType(ViSignalType(inputs[at])), roleFlags: 0, expression: 'a$at'),
        ],
        outputs: [LvPrimTerminal(port: 9, type: mapLvWireType(ViSignalType(output)), roleFlags: 0, expression: 'e0')],
        outputPorts: const [9],
        portDrawnTop: {for (var at = 0; at < inputs.length; at++) at: at},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected, reason: name);
    }
  });

  test('a variadic node with an unwired operand states no value for it', () {
    final type = mapLvWireType(const ViSignalType(0x0230));
    final call = LvPrimCall(
      op: null,
      classCode: LvNodeClass.concatenateStrings.code,
      inputs: [
        for (var at = 0; at < 2; at++) LvPrimTerminal(port: at, type: type, roleFlags: 0, expression: 'a$at'),
      ],
      outputs: [LvPrimTerminal(port: 9, type: type, roleFlags: 0, expression: 'e0')],
      outputPorts: const [9, 10],
      portDrawnTop: const {0: 10, 1: 20},
      requireImport: (_) {},
      names: LvNaming(),
      nodeFlags: null,
    );
    expect(lvPrimLowering(call), isNull);
  });

  test('an ordered operation reads its operands off the drawn order, not the heap order', () {
    const rows = <(String, Map<int, int>, String?)>[
      ('port 0 drawn upper', {0: 10, 1: 40}, 'final int e0 = (a0 - a1) & 0xFFFFFFFF;'),
      ('port 1 drawn upper', {0: 40, 1: 10}, 'final int e0 = (a1 - a0) & 0xFFFFFFFF;'),
      ('drawn on one row', {0: 10, 1: 10}, null),
      ('geometry missing', {0: 10}, null),
    ];
    for (final (name, drawnTop, expected) in rows) {
      final type = mapLvWireType(const ViSignalType(0x0107));
      final call = LvPrimCall(
        op: PrimOp.subtract,
        classCode: 0x2f,
        inputs: [
          for (var at = 0; at < 2; at++) LvPrimTerminal(port: at, type: type, roleFlags: 0, expression: 'a$at'),
        ],
        outputs: [LvPrimTerminal(port: 9, type: type, roleFlags: 0, expression: 'e0')],
        outputPorts: const [9],
        portDrawnTop: drawnTop,
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected == null ? null : [expected], reason: name);
    }
  });

  test('Quotient & Remainder binds each result to the output it is drawn beside', () {
    const rows = <(String, List<int>, List<String?>, List<String>)>[
      ('both results used', [8, 9], ['rem', 'quo'], ['final (quo, rem) = lvQuotientRemainder(a1, a0);']),
      ('quotient only', [8, 9], [null, 'quo'], ['final (quo, _) = lvQuotientRemainder(a1, a0);']),
      ('remainder only', [8, 9], ['rem', null], ['final (_, rem) = lvQuotientRemainder(a1, a0);']),
      ('neither used', [8, 9], [null, null], <String>[]),
    ];
    for (final (name, ports, bindings, expected) in rows) {
      final type = mapLvWireType(const ViSignalType(0x0107));
      final call = LvPrimCall(
        op: PrimOp.quotientRemainder,
        classCode: 0x2f,
        inputs: [
          for (var at = 0; at < 2; at++) LvPrimTerminal(port: at, type: type, roleFlags: 0, expression: 'a$at'),
        ],
        outputs: [
          for (var at = 0; at < 2; at++)
            if (bindings[at] case final name?)
              LvPrimTerminal(port: ports[at], type: type, roleFlags: 0, expression: name),
        ],
        outputPorts: ports,
        portDrawnTop: {0: 40, 1: 10, ports[0]: 10, ports[1]: 40},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected, reason: name);
    }
  });

  test('Index Array lowers a rank-1 group per output and refuses the rest', () {
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
      ('rank 2', [array, first, last], [out], null),
      ('rank 2, first index only', [array, first], [out], null),
      ('rank 2, last index only', [array, last], [out], null),
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
        classCode: LvNodeClass.indexArray.code,
        inputs: [for (var at = 0; at < inputRoles.length; at++) terminal(inputRoles[at], at, isInput: true)],
        outputs: [for (var at = 0; at < outputRoles.length; at++) terminal(outputRoles[at], at, isInput: false)],
        outputPorts: [for (var at = 0; at < outputRoles.length; at++) at],
        portDrawnTop: const {},
        requireImport: (_) {},
        names: LvNaming(),
        nodeFlags: null,
      );
      expect(lvPrimLowering(call), expected, reason: name);
    }
  });

  test('Float32List narrowing is what SGL arithmetic needs', () {
    const sum = 0.1 + 0.2;
    final narrowed = (Float32List(1)..[0] = sum)[0];
    expect(narrowed, isNot(sum));
    expect(narrowed, (Float32List(1)..[0] = 0.30000001192092896)[0]);
  });
}
