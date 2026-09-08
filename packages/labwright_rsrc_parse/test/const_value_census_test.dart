@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

class _Rec {
  _Rec(this.op, this.intValue, this.raw);
  final int op;
  final int? intValue;
  final Uint8List? raw;
  int count = 1;
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
        final prev = recs[cur.oid];
        if (prev == null) {
          recs[cur.oid] = _Rec(body[span.offset], attr.asInt, attr.rawValueBytes);
        } else {
          prev.count++;
        }
      },
    );
    if (recs.isEmpty) continue;
    bump('multiRecordConstants', recs.values.where((r) => r.count > 1).length);

    final diagram = buildDiagram(body, sectionTag: d.tag);
    decodeBdConstValues(diagram);
    for (final e in recs.entries) {
      final o = diagram.byId[e.key];
      if (o == null) continue;
      final rec = e.value;
      if (o.constBool == null &&
          o.kind == HeapObjectClass.bdConstDco.code &&
          diagram.objects.any(
            (k) => k.parentOid == o.oid && k.kind == HeapObjectClass.booleanOrClusterControl.code,
          ) &&
          rec.raw == null &&
          rec.intValue != 0 &&
          rec.intValue != 1) {
        bump('boolNonBinary');
      }
    }
  }
  return c;
}

const kConstValueLawBreaks = <String, Map<String, int>>{};

void main() {
  final all = corpusVis();

  test('BD-constant laws: one record per constant, on the DCO, booleans binary', () async {
    final res = await corpusParallel(all, _census);
    expect(
      perFileNonzero(all, res, const {'recordsOffDco', 'multiRecordConstants', 'boolNonBinary'}),
      kConstValueLawBreaks,
    );
  });
}
