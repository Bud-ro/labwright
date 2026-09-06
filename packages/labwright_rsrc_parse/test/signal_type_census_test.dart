@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

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

(int?, String?) _dimsAndElement(ViType t, List<ViType> pool) {
  var dims = 0;
  var cur = t;
  for (var i = 0; i < 6; i++) {
    if (cur.kind != ViDataType.array) return (dims, _familyOf(cur.kind));
    dims += cur.dimCount ?? 1;
    final e = cur.elementIndex;
    if (e == null || e < 0 || e >= pool.length) return (null, null);
    cur = pool[e];
  }
  return (null, null);
}

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final List<DecodedSection> decoded;
  final ViModel model;
  try {
    decoded = decodeSections(bytes).toList();
    model = buildViModelFromDecoded(decoded);
  } catch (_) {
    return c;
  }
  final pool = model.types;

  final bdBodies = [
    for (final d in decoded)
      if (const {'BDHb', 'BDHP', 'BDEx'}.contains(d.tag) && d.bytes.length >= 6) d.bytes,
  ];
  final stateBySig = <int, Map<int, int>>{};
  final wtScalarBySig = <int, Map<int, int>>{};
  for (var di = 0; di < model.blockDiagrams.length && di < bdBodies.length; di++) {
    final body = bdBodies[di];
    final st = stateBySig[di] = <int, int>{};
    final wt = wtScalarBySig[di] = <int, int>{};
    walkHeapObjects<(int, int)>(
      body,
      onObjectOpen: (span, kind, oid, parent) => (kind, oid),
      onRecord: (span, cur) {
        if (cur == null || cur.$1 != 0x17) return;
        if (span.lead == kHeapRecordPrefix || span.lead == 0x14) return;
        final attr = decodeHeapAttr(body, span.offset);
        if (attr == null) return;
        final v = attr.value;
        if (attr.rawTag == 0x09f && v is int && v > 0xffff) bump('oversizedTypeWord');
        if (attr.rawTag == 0x115 && v is int) st[cur.$2] ??= v;
        if (attr.rawTag == 0x1e7 && attr.width != HeapAttrWidth.container && v is int) wt[cur.$2] ??= v;
      },
    );
  }

  for (var di = 0; di < model.blockDiagrams.length; di++) {
    final diagram = model.blockDiagrams[di];
    for (final wire in diagram.wires) {
      bump('signals');
      final t = wire.signalType;
      if (t == null) {
        bump('noTypeWord');
        continue;
      }
      bump('code_${t.typeCode.toRadixString(16).padLeft(2, '0')}');
      if (t.depth < 1 || t.depth > 6) {
        bump('depthOutOfRange');
      } else {
        bump('depth_${t.depth}');
      }
      if ((t.raw & 0x3000) != 0) bump('flagsLow2Set');
      bump('flag_${t.flags.toRadixString(16)}');
      if (t.dataType == null) bump('codeUncatalogued');
      if (t.typeKind != null) bump('kindResolved');

      final fams = <String>{};
      final nearbyFams = <String>{};
      ViType? oracleType;
      for (final oid in wire.endpointOids) {
        var first = true;
        void see(ViType? r) {
          if (r == null) return;
          final fam = _familyOf(r.kind);
          if (fam != null) {
            nearbyFams.add(fam);
            if (first) {
              fams.add(fam);
              oracleType ??= r;
            }
          }
          first = false;
        }

        var o = diagram.byId[oid];
        for (var lvl = 0; o != null && lvl < 5; lvl++) {
          see(o.resolvedType);
          final p = o.parentOid;
          o = p == null ? null : diagram.byId[p];
        }
        see(diagram.endpointTerminal(oid)?.resolvedType);
      }
      if (fams.length != 1) {
        if (fams.length > 1) bump('oracleConflicted');
        continue;
      }
      final fam = fams.first;

      final st = stateBySig[di]?[wire.signalOid];
      if (st != null) bump('x_st_${st.toRadixString(16)}|$fam');
      final wt = wtScalarBySig[di]?[wire.signalOid];
      if (wt != null) bump('x_wt_${wt.toRadixString(16)}|$fam');
      final of = diagram.byId[wire.signalOid]?.objFlags;
      if (of != null) bump('x_of_${of.toRadixString(16)}|$fam');

      final kind = wire.typeKind;
      final predicted = kind == null ? null : _familyOfKind(kind);
      if (fam == 'enum') {
        bump('oracleEnum');
        if (predicted == 'int') bump('oracleEnumAsInt');
        continue;
      }
      bump('oracle_$fam');
      final (oracleDims, oracleElemFam) = oracleType == null ? (null, null) : _dimsAndElement(oracleType!, pool);
      final elementKind = t.elementKind;
      final wordElemFam = elementKind == null ? null : _familyOfKind(elementKind);

      if (predicted == fam) {
        bump('oracle_${fam}_agree');
      } else {
        final elementMiss =
            (fam == 'array' && oracleElemFam != null && predicted == oracleElemFam) ||
            (fam != 'array' && predicted == 'array' && wordElemFam == fam);
        if (elementMiss) {
          bump('miss_${fam}_element');
        } else if (predicted != null && nearbyFams.contains(predicted)) {
          bump('miss_${fam}_nearby');
        } else {
          bump('miss_${fam}_other');
        }
      }

      final wordDims = t.arrayDims;
      if (wordDims != null && oracleDims != null && oracleElemFam != null && wordElemFam == oracleElemFam) {
        final k = oracleDims > 3 ? '4plus' : '$oracleDims';
        bump('dims$k');
        if (wordDims == oracleDims) bump('dims${k}_agree');
      }
    }
  }
  return c;
}

(int, int) _purity(Map<String, int> agg, String prefix) {
  final byValue = <String, Map<String, int>>{};
  agg.forEach((k, n) {
    if (!k.startsWith(prefix)) return;
    final sep = k.lastIndexOf('|');
    final value = k.substring(prefix.length, sep);
    (byValue[value] ??= {})[k.substring(sep + 1)] = n;
  });
  var pure = 0, total = 0;
  for (final fams in byValue.values) {
    var max = 0, sum = 0;
    for (final n in fams.values) {
      sum += n;
      if (n > max) max = n;
    }
    pure += max;
    total += sum;
  }
  return (pure, total);
}

const _lawKeys = {'depthOutOfRange', 'flagsLow2Set', 'oversizedTypeWord'};

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
    for (final (tag, name) in [('x_st_', 'SignalState'), ('x_wt_', 'WireTableScalar'), ('x_of_', 'ObjFlags')]) {
      final (pure, total) = _purity(C, tag);
      C['ruledOut${name}Pure'] = pure;
      C['ruledOut${name}Total'] = total;
    }
    C.removeWhere((k, _) => k.startsWith('x_'));
  });

  test('wire-type word laws: u16 wide, depth 1..6, flag bits 12-13 clear', () {
    expect(C['oversizedTypeWord'] ?? 0, 0, reason: '0x9f records wider than the documented u16');
    expect(C['depthOutOfRange'] ?? 0, 0, reason: 'depth nibble outside the corpus-pinned 1..6 range');
    expect(C['flagsLow2Set'] ?? 0, 0, reason: 'flag bits 12-13 are zero corpus-wide');
  });

  test('signal wire-type census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('signal_types', {
      for (final e in C.entries)
        if (!_lawKeys.contains(e.key)) e.key: e.value,
    });
  });
}
