@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

Map<String, int> _censusSnippet(Uint8List png, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  bump('snippet_pngs');
  final Raster raster;
  try {
    raster = decodePngRaster(png);
  } catch (_) {
    bump('png_undecodable');
    return c;
  }
  final vi = extractSnippetVi(png);
  if (vi == null) {
    bump('no_embedded_vi');
    return c;
  }
  final interior = snippetDiagramInterior(raster.width, raster.height);
  final decoded = decodeSections(vi).toList();
  final model = buildViModelFromDecoded(decoded);
  if (model.blockDiagrams.isEmpty) return c;
  var bdIndex = 0;
  for (var i = 1; i < model.blockDiagrams.length; i++) {
    if (model.blockDiagrams[i].objects.length > model.blockDiagrams[bdIndex].objects.length) bdIndex = i;
  }
  final bd = model.blockDiagrams[bdIndex];
  final reg = registerDiagram(bd, raster, interior);
  if (reg.max < 150 || reg.score / reg.max < (reg.leafMode ? 0.60 : 0.75)) {
    bump('reg_failed');
    return c;
  }
  bump('reg_ok');

  final state = <int, int>{}, heapOff = <int, int>{};
  final hdrOf = <int, String>{};
  final bodies = [
    for (final d in decoded)
      if (const {'BDHb', 'BDHP', 'BDEx'}.contains(d.tag) && d.bytes.length >= 6) d.bytes,
  ];
  if (bdIndex >= bodies.length) {
    bump('body_index_mismatch');
    return c;
  }
  final body = bodies[bdIndex];
  walkHeapObjects<(int, int)>(
    body,
    onObjectOpen: (span, kind, oid, parent) {
      if (kind == 0x17) heapOff[oid] = span.offset;
      return (kind, oid);
    },
    onRecord: (span, cur) {
      if (cur == null || cur.$1 != 0x17) return;
      if (span.lead == kHeapRecordPrefix || span.lead == 0x14) return;
      final attr = decodeHeapAttr(body, span.offset);
      if (attr == null) return;
      final v = attr.value;
      if (attr.rawTag == 0x115 && v is int) state[cur.$2] ??= v;
      if (attr.rawTag == 0x1e7 && attr.width != HeapAttrWidth.container && v is int) {
        hdrOf[cur.$2] ??= 'h${(v & 0xff).toRadixString(16)}';
      }
    },
  );

  String? selectorLabel(int structOid) {
    for (final o in bd.objects) {
      if (o.parentOid == structOid && o.kind == 0x95 && o.label != null) return o.label;
    }
    return null;
  }

  bool inDisabledFrame(int oid) {
    var o = bd.byId[oid];
    for (var i = 0; o != null && i < 64; i++) {
      final p = o.parentOid == null ? null : bd.byId[o.parentOid!];
      if (p != null && o.kind == 0x1b && p.kind == 0xcd) {
        if ((selectorLabel(p.oid) ?? '').toLowerCase().contains('disabled')) return true;
      }
      o = p;
    }
    return false;
  }

  final runs = wireRuns(bd);
  for (final run in runs) {
    sampleRun(run, raster, interior, reg);
  }

  for (final run in runs) {
    final o = bd.byId[run.sigOid]!;
    final k = o.lastSignalKind ?? 0;
    final cell = '${(k & 0xff).toRadixString(16).padLeft(2, '0')}_d${(k >> 8) & 0xf}';
    final dis = inDisabledFrame(run.sigOid);
    if (run.color != null) {
      bump('${dis ? 'dis' : 'ena'}|$cell|${run.color!.toRadixString(16).padLeft(6, '0')}');
    }
    final style = run.style;
    if (style == null || style == 'blank' || style == 'unsampled' || style == 'aperiodic') {
      if (style != null) bump('run_$style');
      continue;
    }
    if (style.startsWith('lowcover')) {
      bump('run_lowCoverage');
      continue;
    }
    final name = style.startsWith('unclassified') ? 'unclassified' : style;
    if (reg.leafMode) bump('runs_under_leaf_reg');
    final axis = run.horizontal ? 'H' : 'V';
    bump('style|$name|$cell|$axis');
    bump('flag|$cell$axis@f${(k >> 12) & 0xf}|$name');
    bump('state|$cell$axis@s${(state[run.sigOid] ?? -1).toRadixString(16)}|$name');
    bump(
      'hdr|$cell$axis@${o.wireTableRaw != null && o.wireTableRaw!.length > 1 ? 'c${o.wireTableRaw![1].toRadixString(16)}' : (hdrOf[run.sigOid] ?? '-')}|$name',
    );
    bump('objf|$cell$axis@o${o.objFlags?.toRadixString(16) ?? '-'}|$name');
  }

  for (final o in bd.objects) {
    final r = o.absBounds;
    if (r == null || r.width < 12 || r.height < 12) continue;
    if (!objectVisibleInRender(bd, o.oid)) continue;
    String? chromeKey;
    int rowY = r.top;
    if (const {0x20, 0x21}.contains(o.kind)) {
      chromeKey = 'loopBorder';
    } else if (o.kind == 0x0a && !o.isLabelHidden && o.label != null && o.label!.isNotEmpty) {
      chromeKey = 'labelBg';
      rowY = r.top + r.height ~/ 2;
    }
    if (chromeKey == null) continue;
    final votes = <int, int>{};
    for (var x = r.left + r.width ~/ 3; x < r.right - r.width ~/ 3; x++) {
      final px = x - reg.dx + interior.left, py = rowY - reg.dy + interior.top;
      if (px < interior.left || px >= interior.right || py < interior.top || py >= interior.bottom) continue;
      final i = (py * raster.width + px) * 4;
      final rgb = (raster.rgba[i] << 16) | (raster.rgba[i + 1] << 8) | raster.rgba[i + 2];
      votes[rgb] = (votes[rgb] ?? 0) + 1;
    }
    if (votes.isEmpty) continue;
    final top = (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    bump('chrome${inDisabledFrame(o.oid) ? 'D' : 'E'}|$chromeKey|${top.toRadixString(16).padLeft(6, '0')}');
  }

  final wireColors = <int>{for (final s in runs) s.color ?? -1}..remove(-1);
  int rgbAt(int px, int py) {
    final i = (py * raster.width + px) * 4;
    return (raster.rgba[i] << 16) | (raster.rgba[i + 1] << 8) | raster.rgba[i + 2];
  }

  WireRun? matchRun({required bool horizontal, required int axis, required int along, required int color}) {
    for (final s in runs) {
      if (s.horizontal != horizontal || s.color != color) continue;
      if ((s.axisPos - axis).abs() > 6) continue;
      if (along >= s.lo - 8 && along <= s.hi + 8) return s;
    }
    return null;
  }

  void judge({required bool brokenIsH, required int dxDiag, required int dyDiag, required int c, required int centre}) {
    final broken = matchRun(
      horizontal: brokenIsH,
      axis: brokenIsH ? dyDiag : dxDiag,
      along: brokenIsH ? dxDiag : dyDiag,
      color: c,
    );
    final survivor = matchRun(
      horizontal: !brokenIsH,
      axis: brokenIsH ? dxDiag : dyDiag,
      along: brokenIsH ? dyDiag : dxDiag,
      color: centre,
    );
    if (broken == null || survivor == null || broken.sigOid == survivor.sigOid) {
      bump('cross|unattributed');
      return;
    }
    bool patterned(WireRun r) {
      const solid = {'solid1px', 'solid2px', 'hollowDouble'};
      final s = r.style;
      if (s != null && solid.contains(s)) return false;
      if (s != null && !const {'blank', 'unsampled', 'aperiodic'}.contains(s)) return true;
      final word = bd.byId[r.sigOid]?.lastSignalKind;
      final pred = word == null ? null : ViSignalType(word).renderStyleEstimate?.name;
      return pred == null || !solid.contains(pred);
    }

    if (patterned(broken)) {
      bump('cross|patternedCandidate');
      return;
    }
    final later = (heapOff[survivor.sigOid] ?? -1) > (heapOff[broken.sigOid] ?? -1);
    bump('cross|survivor${later ? 'Later' : 'Earlier'}');
    bump('cross|broken${brokenIsH ? 'H' : 'V'}');
  }

  for (var py = interior.top + 3; py < interior.bottom - 5; py++) {
    for (var px = interior.left + 3; px < interior.right - 5; px++) {
      final centre = rgbAt(px, py);
      if (centre == 0xffffff) continue;
      final dxDiag = px - interior.left + reg.dx, dyDiag = py - interior.top + reg.dy;
      for (final wc in wireColors) {
        bool eq(int ox, int oy, int v) => rgbAt(px + ox, py + oy) == v;
        bool ink(int ox, int oy) => rgbAt(px + ox, py + oy) != 0xffffff;
        if (eq(-3, 0, wc) && eq(-2, 0, wc) && eq(-1, 0, 0xffffff)) {
          for (final coreW in const [1, 2]) {
            var core = true;
            for (var i = 0; i < coreW; i++) {
              core = core && ink(i, 0);
            }
            if (!core || !eq(coreW, 0, 0xffffff) || !eq(coreW + 1, 0, wc) || !eq(coreW + 2, 0, wc)) continue;
            judge(brokenIsH: true, dxDiag: dxDiag, dyDiag: dyDiag, c: wc, centre: centre);
            break;
          }
        }
        if (eq(0, -3, wc) && eq(0, -2, wc) && eq(0, -1, 0xffffff)) {
          for (final coreW in const [1, 2]) {
            var core = true;
            for (var i = 0; i < coreW; i++) {
              core = core && ink(0, i);
            }
            if (!core || !eq(0, coreW, 0xffffff) || !eq(0, coreW + 1, wc) || !eq(0, coreW + 2, wc)) continue;
            judge(brokenIsH: false, dxDiag: dxDiag, dyDiag: dyDiag, c: wc, centre: centre);
            break;
          }
        }
      }
    }
  }
  return c;
}

String? _predictedName(String cell) {
  final code = int.parse(cell.split('_')[0], radix: 16);
  final depth = int.parse(cell.split('_d')[1]);
  return ViSignalType((depth << 8) | code).renderStyle?.name;
}

void main() {
  final pngs = listSnippetPngs(corpusViDir);
  if (pngs.isEmpty) {
    test('wire render-style census (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  late final Map<String, int> C;
  setUpAll(() async {
    final res = await corpusParallel(pngs, _censusSnippet);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  test('style is a function of the wire-type word: H cells with >=3 runs match renderStyle', () {
    final violations = <String>[];
    var checked = 0;
    C.forEach((k, n) {
      if (!k.startsWith('style|') || n < 3) return;
      final parts = k.split('|');
      final measured = parts[1], cell = parts[2];
      if (parts[3] != 'H') return;
      if (measured == 'unclassified') return;
      final predicted = _predictedName(cell);
      if (predicted == null) return;
      checked++;
      if (predicted != measured) violations.add('$cell: measured $measured x$n, shipped mapping says $predicted');
    });
    expect(checked, greaterThanOrEqualTo(8), reason: 'the corpus must exercise the mapping');
    expect(violations, isEmpty);
  });

  int expectNoRestyle(Map<String, int> C, String prefix) {
    final byCell = <String, Map<String, Map<String, int>>>{};
    C.forEach((k, n) {
      if (!k.startsWith(prefix)) return;
      final parts = k.split('|');
      final cellValue = parts[1], style = parts[2];
      if (style == 'unclassified') return;
      final at = cellValue.lastIndexOf('@');
      final cell = cellValue.substring(0, at), value = cellValue.substring(at + 1);
      ((byCell[cell] ??= {})[value] ??= {})[style] = (byCell[cell]![value]![style] ?? 0) + n;
    });
    final violations = <String>[];
    var multiValueCells = 0;
    byCell.forEach((cell, byValue) {
      if (byValue.length < 2) return;
      multiValueCells++;
      String majority(Map<String, int> styles) =>
          (styles.entries.toList()
                ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key)))
              .first
              .key;
      final majorities = byValue.values.map(majority).toSet();
      if (majorities.length != 1) violations.add('$prefix$cell majority styles differ across values: $byValue');
    });
    expect(violations, isEmpty);
    return multiValueCells;
  }

  test('the wire-word flag nibble does not restyle a wire', () {
    final cells = expectNoRestyle(C, 'flag|');
    expect(cells, greaterThanOrEqualTo(2), reason: 'need cells sampled under multiple flag values');
  });

  test('signalState 0x115, the 0x1e7 header byte and objFlags do not restyle a wire', () {
    expectNoRestyle(C, 'state|');
    expectNoRestyle(C, 'hdr|');
    expectNoRestyle(C, 'objf|');
  });

  test('crossing rule: the later-serialized signal breaks, the earlier survives', () {
    expect(C['cross|survivorLater'] ?? 0, 0, reason: 'a survivor serialized later refutes the rule');
    expect(C['cross|survivorEarlier'] ?? 0, greaterThanOrEqualTo(4));
  });

  test('disabled-frame palette: measured pairs match dimDisabledFrameRgb', () {
    final enaModal = <String, MapEntry<int, int>>{};
    final disPairs = <String, int>{};
    C.forEach((k, n) {
      final parts = k.split('|');
      if (k.startsWith('ena|')) {
        final cur = enaModal[parts[1]];
        if (cur == null || n > cur.value) enaModal[parts[1]] = MapEntry(int.parse(parts[2], radix: 16), n);
      } else if (k.startsWith('dis|')) {
        disPairs['${parts[1]}|${parts[2]}'] = n;
      }
    });
    expect(disPairs, isNotEmpty, reason: 'the corpus carries disabled-frame wire samples');
    final violations = <String>[];
    disPairs.forEach((key, n) {
      final cell = key.split('|')[0];
      final got = int.parse(key.split('|')[1], radix: 16);
      final ena = enaModal[cell];
      if (ena == null) return;
      final want = dimDisabledFrameRgb(ena.key);
      if (got != want) {
        violations.add(
          '$cell: disabled #${got.toRadixString(16)} x$n vs dim(#${ena.key.toRadixString(16)}) = #${want.toRadixString(16)}',
        );
      }
    });
    expect(violations, isEmpty);
    int modal(String prefix) {
      int best = -1, bestN = -1;
      C.forEach((k, n) {
        if (k.startsWith(prefix) && n > bestN) {
          bestN = n;
          best = int.parse(k.split('|')[2], radix: 16);
        }
      });
      return best;
    }

    final enaBorder = modal('chromeE|loopBorder|'), disBorder = modal('chromeD|loopBorder|');
    expect(enaBorder, isNot(-1), reason: 'no enabled loop-border chrome sampled');
    expect(disBorder, isNot(-1), reason: 'no disabled loop-border chrome sampled');
    expect(disBorder, dimDisabledFrameRgb(enaBorder), reason: 'loop-border chrome pair');
  });

  test('wire render-style census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_render_styles', C);
  });
}
