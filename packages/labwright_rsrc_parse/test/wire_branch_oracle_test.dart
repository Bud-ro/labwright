@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

/// Independent pixel oracle for the branching wire route ([ViWire.routeTree]):
/// the shipping gate proves the LEAF endpoints only, so the interior bends
/// and junction-dot positions — decoded from the stored stream, not
/// re-derived from an endpoint — are corroborated HERE against LabVIEW's own
/// snippet renders. Each registrable snippet's diagram is registered onto its
/// reference raster (the shared [registerDiagram]); then, for every branching
/// signal, the walked tree's runs are sampled pixel-by-pixel for ink overlay
/// and each junction dot is tested for ink.
///
/// Two scopes: **shipped** trees ([ViWire.routeTree] non-null — leaves
/// proven) are the oracle's ground; **walk** trees (origin anchored, not all
/// leaves closed) are reported for context — their far arms drift off the
/// true wire, so their lower coverage is expected, not a defect. Pinned by
/// the `wire_branch_oracle` snapshot section.
///
/// Sample size is small (branching wires are rare in registrable snippets),
/// so this pins the overlay measurement and the junction-on-ink law, not a
/// broad statistical claim; the corpus-wide leaf closure and the rule
/// selection live in `wire_route_census_test`.
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
    bump('brc_reg_failed');
    return c;
  }
  bump('brc_reg_ok');

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

  for (final w in bd.wires) {
    if (w.endpointOids.length < 3) continue;
    final branch = w.branchRoute;
    if (branch == null) continue;
    if (!objectVisibleInRender(bd, w.signalOid)) continue;
    // The 'shipped' scope gates the PROVEN closed tier — the tree the model
    // actually ships ([ViWire.routeTree], closure-arbitrated attach
    // candidates included). Unshipped/partially-anchored wires fall in
    // 'walk' (re-walked from the shell-centre attach), whose far arms
    // drift — that lower coverage is expected. The walked tier's own
    // overlay is pinned by `wire_one_anchored_oracle`.
    final closed = w.routeTree != null && w.routeTreeFidelity == WireRouteFidelity.closed;
    final ViWireRouteTree tree;
    if (closed) {
      tree = w.routeTree!;
    } else {
      final origin = bd.wireAttachPoint(w.endpointOids[0]);
      if (origin == null) continue;
      tree = walkWireBranchRoute(branch, origin);
    }
    final scope = closed ? 'shipped' : 'walk';
    bump('brc_${scope}_wires');
    for (final line in tree.polylines) {
      for (var s = 0; s < line.length - 1; s++) {
        final a = line[s], b = line[s + 1];
        final steps = (a.x - b.x).abs() + (a.y - b.y).abs();
        for (var t = 0; t <= steps; t++) {
          final den = steps == 0 ? 1 : steps;
          final p = (x: a.x + (b.x - a.x) * t ~/ den, y: a.y + (b.y - a.y) * t ~/ den);
          bump('brc_${scope}_runpx');
          if (onInk(p)) bump('brc_${scope}_runink');
        }
      }
    }
    for (final j in tree.junctions) {
      bump('brc_${scope}_junctions');
      if (onInk(j)) bump('brc_${scope}_junc_on_ink');
    }
  }
  return c;
}

void main() {
  final pngs = listSnippetPngs(corpusViDir);
  if (pngs.isEmpty) {
    test('wire branch oracle (skipped: corpus not fetched)', () {}, skip: true);
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

  test('branch oracle laws: shipped junction dots sit on reference ink', () {
    // Every junction dot of a shipped (leaf-proven) tree lands on wire ink —
    // the branch points are where the render draws them.
    expect(C['brc_shipped_junc_on_ink'] ?? 0, C['brc_shipped_junctions'] ?? 0);
    // Shipped runs overlay the render's own ink near-perfectly (>= 99%).
    final px = C['brc_shipped_runpx'] ?? 0, ink = C['brc_shipped_runink'] ?? 0;
    expect(px, greaterThan(0), reason: 'the registrable snippet corpus contains shipped branching trees');
    expect(ink * 100, greaterThanOrEqualTo(99 * px), reason: 'shipped interior geometry overlays reference ink >= 99%');
  });

  test('branch oracle census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_branch_oracle', C);
  });
}
