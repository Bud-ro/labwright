@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

/// Independent pixel oracle for the **one-anchored (walked) wire tier** — the
/// polylines [ViWire.routePoints] / [ViWire.routeTree] ship when only one
/// endpoint resolves an attach point and the far endpoint is a plain-node DCO
/// (a primitive input/output or subVI terminal). The closed tier is proven by
/// two-ended closure; the walked tier is placed by ONE attach point plus the
/// stored table, so it is corroborated HERE against LabVIEW's own snippet
/// renders: each registrable snippet's diagram is registered onto its reference
/// raster (the shared [registerDiagram]), then every walked run is sampled
/// pixel-by-pixel for ink overlay and every plain-node terminus tested for ink.
///
/// The census also measures the **withheld** one-anchored walks (computed but
/// NOT shipped: reverse-with-bends and coarse anchors) so the miss rate that
/// justifies withholding them is pinned, not asserted away. Sample sizes are
/// small (registrable snippets are few), so this pins the overlay measurement
/// and the shipped-tier floor, not a broad statistical claim; the corpus-wide
/// ship counts live in `wire_route_census`.
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
  bump('oa_reg_ok');

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

  // Samples every run of [polys], tallying run pixels/ink under [tier], and
  // returns the aggregate (px, ink) for the per-wire quality bucket.
  (int, int) overlay(String tier, List<List<ViPoint>> polys) {
    var px = 0, ink = 0;
    for (final poly in polys) {
      for (var s = 0; s + 1 < poly.length; s++) {
        final a = poly[s], b = poly[s + 1];
        final steps = (a.x - b.x).abs() + (a.y - b.y).abs();
        for (var t = 0; t <= steps; t++) {
          final den = steps == 0 ? 1 : steps;
          final p = (x: a.x + (b.x - a.x) * t ~/ den, y: a.y + (b.y - a.y) * t ~/ den);
          bump('${tier}_runpx');
          px++;
          if (onInk(p)) {
            bump('${tier}_runink');
            ink++;
          }
        }
      }
    }
    return (px, ink);
  }

  void bucket(String tier, int px, int ink) {
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
      final points = w.routePoints;
      if (points != null && oneAnchored) {
        // Shipped walked polyline.
        bump('oa2_ship_wires');
        final (px, ink) = overlay('oa2_ship', [points]);
        bucket('oa2_ship', px, ink);
        final terminus = a0 != null ? points.last : points.first;
        bump('oa2_ship_term');
        if (onInk(terminus)) bump('oa2_ship_term_ink');
      } else if (points == null && oneAnchored) {
        // Withheld: the walk exists but did not ship (reverse-with-bends or a
        // coarse anchor). Measure what would have shipped.
        final ai = a0 != null ? 0 : 1;
        final farBox = w.endpointAnchors[1 - ai];
        if (farBox == null) continue;
        final poly = walkOneAnchoredRoute(w.route!, anchor: (a0 ?? a1)!, anchoredIndex: ai, farBox: farBox);
        if (poly == null) continue;
        bump('oa2_held_wires');
        final (px, ink) = overlay('oa2_held', [poly]);
        bucket('oa2_held', px, ink);
      }
    } else if (w.endpointOids.length >= 3 && w.branchRoute != null) {
      final origin = bd.wireAttachPoint(w.endpointOids[0]);
      if (origin == null) continue;
      final fullyAnchored = w.endpointOids.every((oid) => bd.wireAttachPoint(oid) != null);
      final tree = w.routeTree;
      if (tree != null && !fullyAnchored) {
        // Shipped walked tree (origin-anchored, contradiction-free).
        bump('oab_ship_wires');
        final (px, ink) = overlay('oab_ship', tree.polylines);
        bucket('oab_ship', px, ink);
        for (final leaf in tree.leaves) {
          bump('oab_ship_leaf');
          if (onInk(leaf)) bump('oab_ship_leaf_ink');
        }
      } else if (tree == null) {
        // Withheld branch walk (origin-anchored but contradicted / mismatched).
        overlay('oab_held', walkWireBranchRoute(w.branchRoute!, origin).polylines);
        bump('oab_held_wires');
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

  test('one-anchored oracle laws: shipped walked routes overlay reference ink', () {
    // Shipped walked two-endpoint polylines overlay LabVIEW's own ink at the
    // both-ended baseline (~96%); reference floor guards against a regression
    // that would ship drifting routes.
    final ship2px = C['oa2_ship_runpx'] ?? 0, ship2ink = C['oa2_ship_runink'] ?? 0;
    expect(ship2px, greaterThan(0), reason: 'the registrable snippets carry shipped walked polylines');
    expect(
      ship2ink * 100,
      greaterThanOrEqualTo(93 * ship2px),
      reason: 'shipped walked polylines overlay reference ink >= 93%',
    );
    // Withheld one-anchored walks overlay measurably WORSE — the miss that
    // justifies withholding them (reverse-with-bends / coarse anchors).
    final held2px = C['oa2_held_runpx'] ?? 0;
    if (held2px > 0) {
      expect(_pct(C, 'oa2_held'), lessThan(_pct(C, 'oa2_ship')), reason: 'withheld walks overlay worse than shipped');
    }
    // Shipped walked branching trees overlay >= 85% (weaker than the closed
    // tier's 99.96%, corroborated not proven).
    final shipBpx = C['oab_ship_runpx'] ?? 0, shipBink = C['oab_ship_runink'] ?? 0;
    if (shipBpx > 0) {
      expect(
        shipBink * 100,
        greaterThanOrEqualTo(85 * shipBpx),
        reason: 'shipped walked trees overlay reference ink >= 85%',
      );
    }
  });

  test('one-anchored oracle census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_one_anchored_oracle', C);
  });
}
