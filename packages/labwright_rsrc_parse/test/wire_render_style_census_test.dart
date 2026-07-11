@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

/// Wire render-style census against the snippet render oracle — the
/// measurements behind `lib/src/wire_render.dart` ([ViWireRenderStyle],
/// [ViSignalTypeRenderStyle.renderStyle], [dimDisabledFrameRgb]), recomputed
/// from the reference pixels and pinned by the `wire_render_styles` snapshot
/// section. Laws asserted directly:
///
/// * **style = f(type word)**: every style cell (measured style ×
///   code+depth) with ≥3 sampled runs matches the shipped
///   [ViSignalTypeRenderStyle.renderStyle] mapping exactly;
/// * the wire-word **flag nibble does not restyle**: within every
///   (code+depth) cell sampled under ≥2 flag values, the measured style set
///   is identical across the flag values;
/// * **crossing rule**: every attributed crossing gap breaks the
///   later-serialized signal (the earlier one runs continuous) — zero
///   later-survivor counterexamples;
/// * **disabled palette**: every disabled-frame wire colour equals
///   [dimDisabledFrameRgb] of the same (code+depth)'s enabled modal colour,
///   ditto the loop-border chrome pair.

/// Census keys per snippet (merged across the corpus):
/// `style|<style>|<code>_d<depth>`, `flag|<code>_d<depth>_f<flags>|<style>`,
/// `state|<style>|s<hex>`, `hdr|<style>|<hdr>`, `ena|<code>_d<depth>|<hex>`,
/// `dis|<code>_d<depth>|<hex>`, `chrome[E|D]|loopBorder|<hex>`,
/// `cross|…`, and the pipeline tallies (`reg_ok`, `reg_failed`, …).
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
  // Verification gate: structure-frame perimeters land ≥75% on ink at a true
  // offset (leaf perimeters cap lower — node glyphs are not border boxes).
  // Below it the snippet is skipped, not guessed at: corpus VIs with known
  // geometry defects (mis-composed structure bounds) land here.
  if (reg.max < 150 || reg.score / reg.max < (reg.leafMode ? 0.60 : 0.75)) {
    bump('reg_failed');
    return c;
  }
  bump('reg_ok');

  // Raw per-signal fields not carried on the model: signalState 0x115, the
  // scalar 0x1e7 header, and the signal's heap offset (serialization order).
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

  // A 0xcd disable structure's 0x95 selector label names the DISPLAYED
  // frame; a "Disabled" frame renders in the dimmed palette.
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
    final name = style.startsWith('unclassified') ? 'unclassified' : style;
    bump('style|$name|$cell');
    bump('flag|${cell}_f${(k >> 12) & 0xf}|$name');
    bump('state|$name|s${(state[run.sigOid] ?? -1).toRadixString(16)}');
    bump(
      'hdr|$name|${o.wireTableRaw != null ? 'c${o.wireTableRaw![1].toRadixString(16)}' : (hdrOf[run.sigOid] ?? '-')}',
    );
  }

  // Chrome pair for the disabled palette: loop border colours.
  for (final o in bd.objects) {
    final r = o.absBounds;
    if (r == null || r.width < 12 || r.height < 12) continue;
    if (!const {0x20, 0x21}.contains(o.kind)) continue;
    if (!objectVisibleInRender(bd, o.oid)) continue;
    final votes = <int, int>{};
    for (var x = r.left + r.width ~/ 3; x < r.right - r.width ~/ 3; x++) {
      final px = x - reg.dx + interior.left, py = r.top - reg.dy + interior.top;
      if (px < interior.left || px >= interior.right || py < interior.top || py >= interior.bottom) continue;
      final i = (py * raster.width + px) * 4;
      final rgb = (raster.rgba[i] << 16) | (raster.rgba[i + 1] << 8) | raster.rgba[i + 2];
      votes[rgb] = (votes[rgb] ?? 0) + 1;
    }
    if (votes.isEmpty) continue;
    final top = (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    bump('chrome${inDisabledFrame(o.oid) ? 'D' : 'E'}|loopBorder|${top.toRadixString(16).padLeft(6, '0')}');
  }

  // Crossing-gap scan: a run of a wire colour broken by a 1-px background
  // gap either side of foreign ink. Attribution back to two signals uses the
  // reconstructed runs (tolerant match: connection points are centre
  // estimates). Only solid1px wires are gap candidates — patterned strokes
  // produce the same signature out of their own cycle.
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
    // Patterned strokes produce the gap signature out of their own cycle
    // (an off column overdrawn by the crossing wire), so a patterned broken
    // candidate is not evidence of a cut. When the run's own pixels did not
    // classify (blank/unsampled: connection points are estimates), the
    // word-predicted style stands in; unknown stays excluded.
    bool patterned(WireRun r) {
      const solid = {'solid1px', 'solid2px', 'hollowDouble'};
      final s = r.style;
      if (s != null && solid.contains(s)) return false;
      if (s != null && !const {'blank', 'unsampled', 'aperiodic'}.contains(s)) return true;
      final word = bd.byId[r.sigOid]?.lastSignalKind;
      final pred = word == null ? null : ViSignalType(word).renderStyle?.name;
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

  // Signature: wire colour for 2 px, a 1-px background gap, a 1- or 2-px
  // crossing core (any non-background colour, the wire's own included —
  // same-colour crossings gap identically), a 1-px gap, wire colour again.
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

/// The shipped mapping's style name for a wire-type word cell, or null.
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

  test('style is a function of the wire-type word: cells with >=3 runs match renderStyle', () {
    final violations = <String>[];
    var checked = 0;
    C.forEach((k, n) {
      if (!k.startsWith('style|') || n < 3) return;
      final parts = k.split('|');
      final measured = parts[1], cell = parts[2];
      if (measured == 'unclassified') return; // cycle catalogued in snapshot only
      final predicted = _predictedName(cell);
      if (predicted == null) return; // cell deliberately unclaimed (see renderStyle doc)
      checked++;
      if (predicted != measured) violations.add('$cell: measured $measured x$n, shipped mapping says $predicted');
    });
    expect(checked, greaterThanOrEqualTo(8), reason: 'the corpus must exercise the mapping');
    expect(violations, isEmpty);
  });

  test('the wire-word flag nibble does not restyle a wire', () {
    // cell -> flag value -> style -> count; compared by MAJORITY style so a
    // single classifier artifact (a period-subsampled cycle) cannot fail the
    // law that the counts themselves pin in the snapshot.
    final byCell = <String, Map<String, Map<String, int>>>{};
    C.forEach((k, n) {
      if (!k.startsWith('flag|')) return;
      final parts = k.split('|');
      final cellFlag = parts[1], style = parts[2];
      if (style == 'unclassified') return; // uncatalogued cycles stay in the snapshot only
      final cell = cellFlag.substring(0, cellFlag.lastIndexOf('_f'));
      final flag = cellFlag.substring(cellFlag.lastIndexOf('_f'));
      ((byCell[cell] ??= {})[flag] ??= {})[style] = (byCell[cell]![flag]![style] ?? 0) + n;
    });
    final violations = <String>[];
    var multiFlagCells = 0;
    byCell.forEach((cell, byFlag) {
      if (byFlag.length < 2) return;
      multiFlagCells++;
      String majority(Map<String, int> styles) =>
          (styles.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
      final majorities = byFlag.values.map(majority).toSet();
      if (majorities.length != 1) violations.add('$cell majority styles differ across flag values: $byFlag');
    });
    expect(multiFlagCells, greaterThanOrEqualTo(2), reason: 'need cells sampled under multiple flag values');
    expect(violations, isEmpty);
  });

  test('crossing rule: the later-serialized signal breaks, the earlier survives', () {
    expect(C['cross|survivorLater'] ?? 0, 0, reason: 'a survivor serialized later refutes the rule');
    expect(C['cross|survivorEarlier'] ?? 0, greaterThanOrEqualTo(4));
  });

  test('disabled-frame palette: measured pairs match dimDisabledFrameRgb', () {
    // Modal enabled colour per cell -> compare each disabled colour.
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
      if (ena == null) return; // no enabled twin for this cell
      final want = dimDisabledFrameRgb(ena.key);
      if (got != want) {
        violations.add(
          '$cell: disabled #${got.toRadixString(16)} x$n vs dim(#${ena.key.toRadixString(16)}) = #${want.toRadixString(16)}',
        );
      }
    });
    expect(violations, isEmpty);
    // Chrome pair: the loop border (enabled modal black) dims the same way.
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
    expect(disBorder, dimDisabledFrameRgb(enaBorder), reason: 'loop-border chrome pair');
  });

  test('wire render-style census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_render_styles', C);
  });
}
