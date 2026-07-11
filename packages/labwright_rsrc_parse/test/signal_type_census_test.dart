@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the signal wire-type-word decode ([ViSignalType] /
/// [ViWire.signalType]) — the numbers its doc comments cite, recomputed from
/// scratch and asserted exactly against the `signal_types` snapshot section.
///
/// Oracle: a signal whose endpoints resolve an unambiguous VCTP data type
/// (the endpoint DCO itself, a near ancestor, or its attach terminal — the
/// same resolution `resolveDataSpaceTypes` performs) is labeled with that
/// type's family; the wire's own decoded [ViWire.typeKind] is scored against
/// it. Enum-labeled wires are scored separately: the type word stores the
/// enum's underlying integer code by design, so they read as int.

/// The wire-level family an oracle endpoint type predicts, or null for the
/// kinds that carry no family claim (typedefs resolve on the wire word but
/// not in this oracle; void/blocks/function are not wire data).
String? _familyOf(ViDataType t) => switch (t) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => 'int',
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => 'float',
  ViDataType.enumU8 || ViDataType.enumU16 || ViDataType.enumU32 => 'enum',
  ViDataType.boolean => 'bool',
  ViDataType.string || ViDataType.cString || ViDataType.pascalString || ViDataType.subString => 'string',
  ViDataType.path => 'path',
  ViDataType.cluster => 'cluster',
  ViDataType.array || ViDataType.subArray || ViDataType.arrayDataPointer => 'array',
  ViDataType.refnum => 'refnum',
  _ => null,
};

/// The oracle family a decoded wire-level [ViTypeKind] counts as agreeing with.
String? _familyOfKind(ViTypeKind kind) => switch (kind) {
  ViTypeKind.numericInt => 'int',
  ViTypeKind.numericFloat => 'float',
  ViTypeKind.enumRing => 'enum',
  ViTypeKind.boolean => 'bool',
  ViTypeKind.string => 'string',
  ViTypeKind.path => 'path',
  ViTypeKind.cluster => 'cluster',
  ViTypeKind.array => 'array',
  ViTypeKind.refnum => 'refnum',
  _ => null,
};

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final ViModel model;
  try {
    model = buildViModel(bytes);
  } catch (_) {
    return c;
  }
  for (final diagram in model.blockDiagrams) {
    for (final wire in diagram.wires) {
      bump('signals');
      final t = wire.signalType;
      if (t == null) {
        bump('noTypeWord');
        continue;
      }
      bump('code_${t.typeCode.toRadixString(16).padLeft(2, '0')}');
      if (t.depth < 1 || t.depth > 6) bump('depthOutOfRange');
      if ((t.raw & 0x3000) != 0) bump('flagsLow2Set');
      if (t.dataType == null) bump('codeUncatalogued');
      if (t.typeKind != null) bump('kindResolved');

      // Oracle label: unanimous endpoint family.
      final fams = <String>{};
      for (final oid in wire.endpointOids) {
        var o = diagram.byId[oid];
        ViDataType? resolved;
        for (var lvl = 0; o != null && lvl < 5; lvl++) {
          resolved = o.dataType;
          if (resolved != null) break;
          final p = o.parentOid;
          o = p == null ? null : diagram.byId[p];
        }
        resolved ??= diagram.endpointTerminal(oid)?.dataType;
        final fam = resolved == null ? null : _familyOf(resolved);
        if (fam != null) fams.add(fam);
      }
      if (fams.length != 1) {
        if (fams.length > 1) bump('oracleConflicted');
        continue;
      }
      final fam = fams.first;
      final kind = wire.typeKind;
      final predicted = kind == null ? null : _familyOfKind(kind);
      if (fam == 'enum') {
        // The word flattens enums to their integer code — scored separately.
        bump('oracleEnum');
        if (predicted == 'int') bump('oracleEnumAsInt');
        continue;
      }
      bump('oracle_$fam');
      if (predicted == fam) bump('oracle_${fam}_agree');
    }
  }
  return c;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('signal wire-type census (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  late final Map<String, int> C;
  setUpAll(() async {
    final res = await corpusParallel(all, _census);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  test('wire-type word laws: depth 1..6, flag bits 12-13 clear', () {
    expect(C['depthOutOfRange'] ?? 0, 0, reason: 'depth nibble outside the corpus-pinned 1..6 range');
    expect(C['flagsLow2Set'] ?? 0, 0, reason: 'flag bits 12-13 are zero corpus-wide');
  });

  test('signal wire-type census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('signal_types', {
      for (final e in C.entries)
        if (e.key != 'depthOutOfRange' && e.key != 'flagsLow2Set') e.key: e.value,
    });
  });
}
