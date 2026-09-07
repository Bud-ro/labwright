@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'wire_style_oracle.dart';

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
  late final Map<String, int> C;
  setUpAll(() async {
    final res = await Future.wait([for (final f in pngs) Future(() => _census(f.readAsBytesSync(), f.path))]);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  test('branch oracle laws: shipped junction dots sit on reference ink', () {
    expect(C['brc_shipped_junc_on_ink'] ?? 0, C['brc_shipped_junctions'] ?? 0);
    final px = C['brc_shipped_runpx'] ?? 0, ink = C['brc_shipped_runink'] ?? 0;
    expect(px, greaterThan(0), reason: 'the registrable snippet corpus contains shipped branching trees');
    expect(ink * 100, greaterThanOrEqualTo(99 * px), reason: 'shipped interior geometry overlays reference ink >= 99%');
  });

  test('branch oracle census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_branch_oracle', C);
  });
}
