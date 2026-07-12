@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

/// Independent pixel oracle for the **one-anchored (walked) wire tier** — the
/// polylines [ViWire.routePoints] / [ViWire.routeTree] ship
/// ([WireRouteFidelity.walked]) when only one endpoint resolves an attach point
/// and the far endpoint is a plain-node DCO (a primitive input/output or subVI
/// terminal). The closed tier is proven by two-ended closure; the walked tier
/// is placed by ONE attach point plus the stored table, so it is corroborated
/// HERE against LabVIEW's own snippet renders.
///
/// **The headline signal is RUN overlay** — the fraction of a wire's PATH
/// pixels that land on reference ink. The terminus-on-ink figure is NOT
/// evidence the far end connects to the correct terminal: the walked terminus
/// is snapped onto the far node's box edge, and the whole edge is ink, so it
/// proves only "on the node outline," never "the right pin." It is recorded but
/// never asserted as far-end correctness.
///
/// **Registration control.** Each snippet's diagram is registered onto its
/// raster ([registerDiagram]); registration can still drift locally on a large
/// diagram, which would make EVERY overlay there meaningless. So each snippet is
/// gated on its CLOSED-tier control overlay (proven geometry): a snippet whose
/// closed two-endpoint routes overlay below 90% is discarded from the walked
/// census (`oa_reg_control_skip`) — its registration is untrustworthy.
///
/// The census also measures the **withheld** one-anchored walks (computed but
/// NOT shipped) so the miss that justifies withholding them is pinned. Sample
/// sizes are small; this pins the overlay measurement and the zero-gross-miss
/// law, not a broad statistical claim. Corpus-wide ship counts live in
/// `wire_route_census`.
Map<String, int> _census(Uint8List png, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final Raster raster;
  try {
    raster = decodePngRaster(png);
  } catch (_) {
    return c;
  }
  final vi = extractSnippetVi(png);
  if (vi == null) return c;
  final interior = snippetDiagramInterior(raster.width, raster.height);
  final model = buildViModelFromDecoded(decodeSections(vi));
  if (model.blockDiagrams.isEmpty) return c;
  var bi = 0;
  for (var i = 1; i < model.blockDiagrams.length; i++) {
    if (model.blockDiagrams[i].objects.length > model.blockDiagrams[bi].objects.length) bi = i;
  }
  final bd = model.blockDiagrams[bi];
  final reg = registerDiagram(bd, raster, interior);
  if (reg.max < 150 || reg.score / reg.max < (reg.leafMode ? 0.60 : 0.75)) {
    bump('oa_reg_failed');
    return c;
  }

  bool onInk(ViPoint p) {
    final px = p.x - reg.dx + interior.left, py = p.y - reg.dy + interior.top;
    for (var oy = -1; oy <= 1; oy++) {
      for (var ox = -1; ox <= 1; ox++) {
        final x = px + ox, y = py + oy;
        if (x < interior.left || x >= interior.right || y < interior.top || y >= interior.bottom) continue;
        final o = (y * raster.width + x) * 4;
        if (raster.rgba[o] <= 210 || raster.rgba[o + 1] <= 210 || raster.rgba[o + 2] <= 210) return true;
      }
    }
    return false;
  }

  // Pixel overlay (px, ink) of a wire's polylines — no side effects, so the
  // control pass can measure without recording.
  (int, int) measure(List<List<ViPoint>> polys) {
    var px = 0, ink = 0;
    for (final poly in polys) {
      for (var s = 0; s + 1 < poly.length; s++) {
        final a = poly[s], b = poly[s + 1];
        final steps = (a.x - b.x).abs() + (a.y - b.y).abs();
        for (var t = 0; t <= steps; t++) {
          final den = steps == 0 ? 1 : steps;
          final p = (x: a.x + (b.x - a.x) * t ~/ den, y: a.y + (b.y - a.y) * t ~/ den);
          px++;
          if (onInk(p)) ink++;
        }
      }
    }
    return (px, ink);
  }

  // Registration control: the closed two-endpoint tier is proven geometry, so
  // its overlay measures how faithfully THIS snippet registers. Below 90% (with
  // enough sampled pixels to trust) the registration is unreliable and the
  // whole snippet is discarded from the walked census.
  var ctrlPx = 0, ctrlInk = 0;
  for (final w in bd.wires) {
    if (w.endpointOids.length != 2 || w.routePointsFidelity != WireRouteFidelity.closed) continue;
    if (!objectVisibleInRender(bd, w.signalOid)) continue;
    final (px, ink) = measure([w.routePoints!]);
    ctrlPx += px;
    ctrlInk += ink;
  }
  const kMinControlPx = 40;
  if (ctrlPx >= kMinControlPx && ctrlInk * 100 < 90 * ctrlPx) {
    bump('oa_reg_control_skip');
    return c;
  }
  bump('oa_reg_ok');
  // The closed-tier baseline (pinned): the proven-geometry overlay this
  // snippet corpus achieves, the bar the walked tier is compared against.
  bump('oa2_closed_runpx', ctrlPx);
  bump('oa2_closed_runink', ctrlInk);

  void record(String tier, List<List<ViPoint>> polys) {
    final (px, ink) = measure(polys);
    bump('${tier}_runpx', px);
    bump('${tier}_runink', ink);
    bump('${tier}_wires');
    final q = px == 0 ? 1.0 : ink / px;
    bump(
      '${tier}_q${q >= 0.95
          ? '95'
          : q >= 0.8
          ? '80'
          : q >= 0.5
          ? '50'
          : 'lo'}',
    );
  }

  for (final w in bd.wires) {
    if (!objectVisibleInRender(bd, w.signalOid)) continue;

    if (w.endpointOids.length == 2 && w.route != null) {
      final a0 = bd.wireAttachPoint(w.endpointOids[0]);
      final a1 = bd.wireAttachPoint(w.endpointOids[1]);
      final oneAnchored = (a0 == null) ^ (a1 == null);
      if (w.routePointsFidelity == WireRouteFidelity.walked) {
        record('oa2_ship', [w.routePoints!]);
        // Terminus-on-ink: recorded, NOT asserted — a box-edge snap lands on
        // the node outline regardless of the exact pin (see the library doc).
        final terminus = a0 != null ? w.routePoints!.last : w.routePoints!.first;
        bump('oa2_ship_term');
        if (onInk(terminus)) bump('oa2_ship_term_ink');
      } else if (w.routePoints == null && oneAnchored) {
        // Withheld: the walk exists but did not ship. Measure what it would be.
        final ai = a0 != null ? 0 : 1;
        final farBox = w.endpointAnchors[1 - ai];
        if (farBox == null) continue;
        final poly = walkOneAnchoredRoute(w.route!, anchor: (a0 ?? a1)!, anchoredIndex: ai, farBox: farBox);
        if (poly != null) record('oa2_held', [poly.points]);
      }
    } else if (w.endpointOids.length >= 3 && w.branchRoute != null) {
      if (w.routeTreeFidelity == WireRouteFidelity.walked) {
        final tree = w.routeTree!;
        record('oab_ship', tree.polylines);
        for (final leaf in tree.leaves) {
          bump('oab_ship_leaf');
          if (onInk(leaf)) bump('oab_ship_leaf_ink');
        }
      } else if (w.routeTree == null) {
        final origin = bd.wireAttachPoint(w.endpointOids[0]);
        if (origin != null) record('oab_held', walkWireBranchRoute(w.branchRoute!, origin).polylines);
      }
    }
  }
  return c;
}

/// Ink-overlay percentage of a tier (runink / runpx), or -1 when unsampled.
int _pct(Map<String, int> c, String tier) {
  final px = c['${tier}_runpx'] ?? 0;
  if (px == 0) return -1;
  return (100 * (c['${tier}_runink'] ?? 0) / px).round();
}

void main() {
  final pngs = listSnippetPngs(corpusViDir);
  if (pngs.isEmpty) {
    test('wire one-anchored oracle (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final Map<String, int> C;
  setUpAll(() async {
    final res = await Future.wait([for (final f in pngs) Future(() => _census(f.readAsBytesSync(), f.path))]);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  test('one-anchored oracle law: NO shipped two-endpoint walk grossly misses the ink', () {
    // The real gate: the structural ship gate (exact anchor, forward or
    // reverse-straight, cross-axis containment, no shift-register bent anchor)
    // admits ZERO shipped two-endpoint walks below 50% path overlay. The
    // aggregate floor below is secondary; this per-wire law is what proves no
    // fabricated route is silently shipped.
    expect(C['oa2_ship_wires'] ?? 0, greaterThan(0), reason: 'the snippets carry shipped walked polylines');
    expect(C['oa2_ship_qlo'] ?? 0, 0, reason: 'no shipped two-endpoint walk overlays below 50% ink');
    // Path overlay stays at the proven closed-tier's own snippet level.
    final shipPx = C['oa2_ship_runpx'] ?? 0, shipInk = C['oa2_ship_runink'] ?? 0;
    expect(
      shipInk * 100,
      greaterThanOrEqualTo(93 * shipPx),
      reason: 'shipped walked paths overlay reference ink >= 93%',
    );
    expect(
      _pct(C, 'oa2_ship'),
      greaterThanOrEqualTo(_pct(C, 'oa2_closed') - 3),
      reason: 'shipped walked overlay tracks the closed-tier control',
    );
    // Withheld one-anchored walks overlay measurably WORSE — the miss that
    // justifies the gate withholding them.
    if ((C['oa2_held_runpx'] ?? 0) > 0) {
      expect(_pct(C, 'oa2_held'), lessThan(_pct(C, 'oa2_ship')), reason: 'withheld walks overlay worse than shipped');
    }
  });

  test('one-anchored oracle: shipped branch trees overlay well, with a documented drift residue', () {
    final shipPx = C['oab_ship_runpx'] ?? 0, shipInk = C['oab_ship_runink'] ?? 0;
    if (shipPx == 0) return;
    // Walked branch trees are DECODED LabVIEW geometry (not fabricated) placed
    // from the origin; overall they overlay well.
    expect(
      shipInk * 100,
      greaterThanOrEqualTo(85 * shipPx),
      reason: 'shipped walked trees overlay reference ink >= 85%',
    );
    // A residue overlays below 50%: junction-catalog drift on a plain-node arm
    // that no resolved leaf can close against — the drift the closed tier
    // rejects via leaf closure but the walked tier cannot detect at decode
    // time (no structural signal isolates it; corroboration/containment/junction
    // -risk gates were measured and do not separate it). Bounded as a
    // regression guard; the exact count is pinned by the snapshot.
    final qlo = C['oab_ship_qlo'] ?? 0, wires = C['oab_ship_wires'] ?? 1;
    expect(
      qlo * 20,
      lessThanOrEqualTo(wires),
      reason: 'walked-branch gross-miss residue stays under 5% (drift on plain-node arms)',
    );
  });

  test('one-anchored oracle census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_one_anchored_oracle', C);
  });
}
