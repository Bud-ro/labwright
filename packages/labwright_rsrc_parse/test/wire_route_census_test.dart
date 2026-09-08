@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final ViModel model;
  try {
    model = buildViModelFromDecoded(decodeSections(bytes));
  } catch (_) {
    return c;
  }
  for (final d in model.blockDiagrams) {
    for (final w in d.wires) {
      final raw = d.byId[w.signalOid]?.wireTableRaw;
      if (raw == null) continue;
      final eps = w.endpointOids.length;
      for (final oid in w.endpointOids) {
        final ep = d.byId[oid];
        if (ep != null && ep.kind == 0x15 && ep.absBounds != null) bump('bounded15Endpoints');
      }
      if (raw.length == 3) bump('tables3Byte');
      if (eps != 2) {
        if (raw.length >= 2 && raw[1] == 0 && eps >= 3) _extCensus(d, w, bump);
        continue;
      }
      if (raw.length >= 2 && raw[1] == 0) bump('ext2ep');
      final route = w.route;
      if (route == null) continue;
      final s = d.wireAttachPoint(w.endpointOids[0]);
      final t = d.wireAttachPoint(w.endpointOids[1]);
      ViPoint? altOf(int oid) {
        final elem = d.endpointConstantElementBounds(oid);
        return elem == null
            ? null
            : (
                x: elem.left + (elem.right - elem.left) ~/ 2,
                y: elem.top + (elem.bottom - elem.top) ~/ 2,
              );
      }

      final sAlt = altOf(w.endpointOids[0]);
      final tAlt = altOf(w.endpointOids[1]);
      final tStrip = _stripTargetOf(d, w, 1);
      final points = w.routePoints;
      if (points != null) {
        bump('shipped');
        final walked = w.routePointsFidelity == WireRouteFidelity.walked;
        if (!walked) {
          bump(s != null && t != null ? 'shippedClosed' : 'shippedClosedDcoChild');
        } else if (s != null || t != null) {
          bump(s != null ? 'shippedWalkedFwd' : 'shippedWalkedRev');
        } else {
          bump('shippedWalkedDcoRow');
        }
        if (w.routePointsFidelity == null) bump('fidelityBad');
        final lenOk = points.length == route.pointCount || points.length == route.pointCount - 1;
        final fb0 = d.dcoChildTerminalAttach(w.endpointOids[0]);
        final fb1 = d.dcoChildTerminalAttach(w.endpointOids[1]);
        final sourceSet = {
          if (s != null) ...{s, if (sAlt != null) sAlt} else ...?fb0?.candidates,
        };
        final targetSet = {
          if (t != null) ...{t, if (tAlt != null) tAlt, if (tStrip != null) tStrip} else ...?fb1?.candidates,
        };
        final bool anchorOk;
        if (!walked) {
          anchorOk = sourceSet.contains(points.first) && targetSet.contains(points.last);
        } else if (s != null) {
          anchorOk = points.first == s;
        } else if (t != null) {
          anchorOk = points.last == t;
        } else {
          anchorOk = sourceSet.contains(points.first) || targetSet.contains(points.last);
        }
        if (!lenOk || !anchorOk) bump('shippedBad');
      }
    }
  }
  return c;
}

void _extCensus(ViDiagram d, ViWire w, void Function(String, [int]) bump) {
  final branch = w.branchRoute;
  if (branch == null) {
    bump('extUndecoded');
    return;
  }
  final eps = w.endpointOids.length;
  final modes = branch.modes;

  final pops = modes.skip(1).where((m) => m == ViWireBranchRoute.popCode).length;
  if (pops + 2 != eps) bump('extLeafLawViol');
  final attach = [for (final oid in w.endpointOids) d.wireAttachPoint(oid)];
  final altAttach = [
    for (final oid in w.endpointOids)
      switch (d.endpointConstantElementBounds(oid)) {
        null => null,
        final elem => (
          x: elem.left + (elem.right - elem.left) ~/ 2,
          y: elem.top + (elem.bottom - elem.top) ~/ 2,
        ),
      },
  ];
  final fullyAnchored = attach.every((p) => p != null);
  if (fullyAnchored) {
    bump('extFullAnchored');
    if (pops + 2 != eps) bump('extFullLeafMismatch');
  }
  final strip = [for (var i = 0; i < eps; i++) _stripTargetOf(d, w, i)];
  bool hitOf(List<ViPoint> pool, int i) =>
      (strip[i] != null && pool.remove(strip[i])) ||
      pool.remove(attach[i]) ||
      (altAttach[i] != null && pool.remove(altAttach[i]));

  if (attach[0] == null) {
    final tree = w.routeTree;
    if (tree != null) {
      bump('extShipped');
      if (w.routeTreeFidelity == WireRouteFidelity.closed) {
        bump('extShippedDcoClosed');
        return;
      }
      bump('extShippedRev');
      if (w.routeTreeFidelity != WireRouteFidelity.walked) bump('extFidelityBad');
      final pool = List<ViPoint>.of(tree.leaves);
      for (var i = 1; i < eps; i++) {
        if (attach[i] != null) hitOf(pool, i);
      }
    }
    return;
  }
  ViWireRouteTree walkFrom(ViPoint origin) => walkWireBranchRoute(branch, origin);
  int leafHits(ViWireRouteTree t) {
    final pool = List<ViPoint>.of(t.leaves);
    var n = 0;
    for (var i = 1; i < eps; i++) {
      if (attach[i] == null) continue;
      if (hitOf(pool, i)) n++;
    }
    return n;
  }

  var tree = walkFrom(attach[0]!);
  if (altAttach[0] != null) {
    final altTree = walkFrom(altAttach[0]!);
    if (leafHits(altTree) > leafHits(tree)) tree = altTree;
  }
  final vertices = {for (final line in tree.polylines) ...line};
  for (final j in tree.junctions) {
    if (!vertices.contains(j)) bump('extJuncOffVertex');
  }
  final leaves = tree.leaves;
  if (leaves.length != eps - 1) {
    return;
  }

  final pool = List<ViPoint>.of(leaves);
  var anchored = 0, hits = 0;
  for (var i = 1; i < eps; i++) {
    if (attach[i] == null) continue;
    anchored++;
    if (hitOf(pool, i)) hits++;
  }
  if (anchored == eps - 1) bump(hits == anchored ? 'extFullClosed' : 'extFullMiss');
  if (w.routeTree != null) {
    bump('extShipped');
    bump(fullyAnchored ? 'extShippedClosed' : 'extShippedWalked');
    if (w.routeTreeFidelity != (fullyAnchored ? WireRouteFidelity.closed : WireRouteFidelity.walked)) {
      bump('extFidelityBad');
    }
  }
}

ViPoint? _stripTargetOf(ViDiagram d, ViWire w, int i) {
  final rect = w.endpointAttachRects[i];
  final p = d.wireAttachPoint(w.endpointOids[i]);
  if (rect == null || p == null) return null;
  if (rect.right - rect.left != kTerminalStripColumnWidth) return null;
  if (!kNodeTerminalStripClasses.contains(d.endpointTerminal(w.endpointOids[i])?.kind)) return null;
  return (x: p.x - kTerminalStripTargetLeftOffset, y: p.y);
}

({int x, int y, bool horizontal, int sign})? _openLanding(ViWireRoute route, ({int x, int y}) s) {
  final direction = route.direction;
  if (direction == null) return null;
  var x = s.x, y = s.y;
  var horizontal = direction.isHorizontal;
  var sign = direction.dx + direction.dy;
  for (var k = 0; k < route.segmentLengths.length; k++) {
    if (k > 0) sign = route.jointSigns[k - 1];
    if (horizontal) {
      x += route.segmentLengths[k] * sign;
    } else {
      y += route.segmentLengths[k] * sign;
    }
    horizontal = !horizontal;
  }
  final closingSign = route.jointSigns.isEmpty ? sign : route.jointSigns.last;
  return (x: x, y: y, horizontal: horizontal, sign: closingSign);
}

const _laws = {
  'ext2ep',
  'shippedBad',
  'fidelityBad',
  'extFidelityBad',
  'bounded15Endpoints',
  'tables3Byte',
  'extUndecoded',
  'extJuncOffVertex',
  'shippedTierMismatch',
  'extShippedTierMismatch',
  'extClosedMismatch',
  'extAnchoredMismatch',
};

const kWireRouteViolations = <String, Map<String, int>>{};

int _sum(Map<String, int> c, List<String> keys) => keys.fold(0, (a, k) => a + (c[k] ?? 0));

void main() {
  final all = corpusVis();

  test('every VI obeys the wire route laws', () async {
    final res = await corpusParallel(all, _census);
    for (final c in res) {
      c['shippedTierMismatch'] =
          ((c['shipped'] ?? 0) -
                  _sum(c, [
                    'shippedClosed',
                    'shippedClosedDcoChild',
                    'shippedWalkedFwd',
                    'shippedWalkedRev',
                    'shippedWalkedDcoRow',
                  ]))
              .abs();
      c['extShippedTierMismatch'] =
          ((c['extShipped'] ?? 0) -
                  _sum(c, ['extShippedClosed', 'extShippedWalked', 'extShippedRev', 'extShippedDcoClosed']))
              .abs();
      c['extClosedMismatch'] = ((c['extShippedClosed'] ?? 0) - (c['extFullClosed'] ?? 0)).abs();
      c['extAnchoredMismatch'] =
          ((c['extFullAnchored'] ?? 0) - _sum(c, ['extFullClosed', 'extFullMiss', 'extFullLeafMismatch'])).abs();
    }
    expect(perFileNonzero(all, res, _laws), kWireRouteViolations);
  });

  test('basic.png ground truth: decoded routes reproduce the reference render geometry', () {
    final candidates = corpusViDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.replaceAll(r'\', '/').endsWith('/Snippets/basic.png'))
        .toList();
    expect(candidates, hasLength(1));
    final vi = extractSnippetVi(candidates.single.readAsBytesSync())!;
    final d = buildViModelFromDecoded(decodeSections(vi)).blockDiagrams.single;
    ViWire wireAt(ViPoint p) => d.wires.singleWhere((w) => d.wireAttachPoint(w.endpointOids[0]) == p);
    final x = wireAt((x: 74, y: 9)), y = wireAt((x: 74, y: 43));
    expect(x.route!.direction, WireRouteDirection.right);
    expect(x.route!.segmentLengths, [28, 12]);
    expect(x.route!.jointSigns, [1, 1]);
    expect(y.route!.jointSigns, [-1, 1]);
    final landX = _openLanding(x.route!, (x: 74, y: 9))!;
    expect((landX.x, landX.y, landX.horizontal, landX.sign), (102, 21, true, 1));
    final landY = _openLanding(y.route!, (x: 74, y: 43))!;
    expect((landY.x, landY.y), (102, 31));
    expect(d.wireAttachPoint(x.endpointOids[1]), isNull);
    expect(x.routePoints, [(x: 74, y: 9), (x: 102, y: 9), (x: 102, y: 21), (x: 106, y: 21)]);
    final straight = d.wires.singleWhere((w) => w.signalOid != x.signalOid && w.signalOid != y.signalOid);
    expect((straight.route!.pointCount, straight.route!.direction), (2, WireRouteDirection.right));
  });
}
