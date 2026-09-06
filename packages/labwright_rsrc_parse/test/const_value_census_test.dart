@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

const _intFamily = {
  ViDataType.i8,
  ViDataType.i16,
  ViDataType.i32,
  ViDataType.i64,
  ViDataType.u8,
  ViDataType.u16,
  ViDataType.u32,
  ViDataType.u64,
  ViDataType.enumU8,
  ViDataType.enumU16,
  ViDataType.enumU32,
  ViDataType.typeDef,
};

class _Rec {
  _Rec(this.op, this.intValue, this.raw);
  final int op;
  final int? intValue;
  final Uint8List? raw;
  int count = 1;
}

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _canonical(_Rec rec, int width) {
  final raw = rec.raw;
  if (raw != null) return raw;
  final out = Uint8List(width);
  var x = rec.intValue ?? 0;
  for (var i = width - 1; i >= 0 && x != 0; i--) {
    out[i] = x & 0xff;
    x >>>= 8;
  }
  return out;
}

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final List<DecodedSection> decoded;
  try {
    decoded = decodeSections(bytes);
  } catch (_) {
    return c;
  }
  Uint8List? vctp, tm80, dfds;
  for (final d in decoded) {
    if (d.tag == 'VCTP') vctp ??= d.bytes;
    if (d.tag == 'TM80') tm80 ??= d.bytes;
    if (d.tag == 'DFDS') dfds ??= d.bytes;
  }

  Map<int, List<DataSpaceSlot>>? slotsByLen;
  List<ViType> pool = const [];
  List<int> table = const [];
  if (vctp != null && tm80 != null && dfds != null) {
    final versionWord = versionWordFromSections([for (final d in decoded) d.section]);
    final slots = dataSpaceSlots(dfds, DfdsContext(vctp: vctp, tm80: tm80, verGe10: (versionWord?.major ?? 0) >= 10));
    if (slots != null) {
      slotsByLen = {};
      for (final s in slots) {
        (slotsByLen[s.length] ??= []).add(s);
      }
      pool = decodeTypePool(vctp);
      table = decodeTypeTable(vctp);
    }
  }
  ViDataType? groundTruth(_Rec rec) {
    if (slotsByLen == null || pool.isEmpty || table.isEmpty) return null;
    DataSpaceSlot? only;
    for (final entry in slotsByLen.entries) {
      final heap = _canonical(rec, entry.key);
      if (heap.length != entry.key) continue;
      var nonzero = false;
      for (final b in heap) {
        if (b != 0) {
          nonzero = true;
          break;
        }
      }
      if (!nonzero || heap.length < 2) continue;
      for (final s in entry.value) {
        if (_bytesEq(heap, Uint8List.sublistView(dfds!, s.offset, s.offset + s.length))) {
          if (only != null) return null;
          only = s;
        }
      }
    }
    if (only == null || only.topLevelIndex < 0 || only.topLevelIndex >= table.length) return null;
    final pi = table[only.topLevelIndex];
    return pi < pool.length ? pool[pi].kind : null;
  }

  for (final d in decoded) {
    if (d.bytes.length < 6 || !const {'BDHb', 'BDHP', 'BDEx'}.contains(d.tag)) continue;
    final body = d.bytes;
    final recs = <int, _Rec>{};
    walkHeapObjects<({int kind, int oid})>(
      body,
      onObjectOpen: (span, kind, oid, parent) => (kind: kind, oid: oid),
      onRecord: (span, cur) {
        if (cur == null) return;
        final attr = decodeHeapAttr(body, span.offset);
        if (attr == null || attr.attribute != HeapAttribute.constValue) return;
        if (cur.kind != HeapObjectClass.bdConstDco.code) {
          bump('recordsOffDco');
          return;
        }
        bump('records');
        final prev = recs[cur.oid];
        if (prev == null) {
          recs[cur.oid] = _Rec(body[span.offset], attr.asInt, attr.rawValueBytes);
        } else {
          prev.count++;
        }
      },
    );
    if (recs.isEmpty) continue;
    bump('constants', recs.length);
    bump('multiRecordConstants', recs.values.where((r) => r.count > 1).length);

    final diagram = buildDiagram(body, sectionTag: d.tag);
    decodeBdConstValues(diagram);
    for (final e in recs.entries) {
      final o = diagram.byId[e.key];
      if (o == null) continue;
      final rec = e.value;
      final scalar = rec.raw == null;
      if (o.constBool != null) {
        bump('decodedBool');
        final hi = rec.op >> 4;
        bump(scalar && (hi <= 0x2 || hi == 0xe) ? 'bool1Byte' : 'bool2Byte');
      } else if (o.kind == HeapObjectClass.bdConstDco.code &&
          diagram.objects.any(
            (k) => k.parentOid == o.oid && k.kind == HeapObjectClass.booleanOrClusterControl.code,
          ) &&
          scalar &&
          rec.intValue != 0 &&
          rec.intValue != 1) {
        bump('boolNonBinary');
      }
      final n = o.constNumeric;
      if (n is int) bump('decodedInt');
      if (n is double) bump('decodedDouble');
      if (o.constText != null) bump('decodedText');
      if (o.constBool == null && n == null && o.constText == null) bump('undecoded');

      if (n != null || o.constText != null) {
        final t = groundTruth(rec);
        if (t == null) continue;
        if (n is int) {
          bump('gtInt');
          if (_intFamily.contains(t)) bump('gtIntIntFamily');
        } else if (n is double) {
          bump('gtDouble');
          if (t == ViDataType.dbl) bump('gtDoubleDbl');
        } else {
          bump('gtText');
          if (t == ViDataType.string) bump('gtTextString');
          if (t != ViDataType.string) bump('gtTextOther:${t.name}');
        }
      }
    }
  }
  return c;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('BD-constant value census (skipped: corpus not fetched)', () {}, skip: true);
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

  test('BD-constant value laws: one record per constant, on the DCO, booleans binary', () {
    expect(C['recordsOffDco'] ?? 0, 0, reason: 'constValue records off the 0x13 DCO');
    expect(C['multiRecordConstants'] ?? 0, 0, reason: 'constants with a second record');
    expect(C['boolNonBinary'] ?? 0, 0, reason: '0x4f scalar payloads outside {0,1}');
  });

  test('BD-constant decode/ground-truth census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('bd_const_values', {
      for (final e in C.entries)
        if (e.key != 'recordsOffDco' && e.key != 'multiRecordConstants' && e.key != 'boolNonBinary') e.key: e.value,
    });
  });
}
