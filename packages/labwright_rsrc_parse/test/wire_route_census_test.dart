@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

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
      final eps = w.endpointOids.length;
      for (final oid in w.endpointOids) {
        final ep = d.byId[oid];
        if (ep != null && ep.kind == 0x15 && ep.absBounds != null) bump('bounded15Endpoints');
      }
      if (raw == null) {
        bump(eps == 2 ? 'noTable2ep' : 'noTableMulti');
        continue;
      }
      if (raw.length == 3) bump('tables3Byte');
      if (eps != 2) {
        final ext = raw.length >= 2 && raw[1] == 0;
        bump(ext ? 'multiExtTable' : 'multiShortTable');
        if (ext && eps < 3) bump('multiExtTableSub3');
        if (ext && eps >= 3) _extCensus(d, w, bump);
        continue;
      }
      bump('tables2ep');
      if (raw.length >= 2 && raw[1] == 0) bump('ext2ep');
      final route = w.route;
      if (route == null) {
        bump('undecoded2ep');
        bump('undecoded2epHdr${raw.length < 2 ? 'None' : raw[1].toRadixString(16)}');
        continue;
      }
      switch (route.direction) {
        case WireRouteDirection.right:
          bump('dirRight');
        case WireRouteDirection.down:
          bump('dirDown');
        case WireRouteDirection.up:
          bump('dirUp');
        case WireRouteDirection.left:
          bump('dirLeft');
        case null:
          bump('onePoint');
      }
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
        if (w.routeClosingStep != null) {
          bump('shippedWalkedIntoNode');
        } else if (points.length == route.pointCount - 1) {
          bump('shippedZeroClose');
          final closingSign = route.jointSigns.isEmpty ? null : route.jointSigns.last;
          bump(
            'zeroCloseSign${closingSign == null
                ? 'None'
                : closingSign > 0
                ? 'Pos'
                : 'Neg'}',
          );
        }
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
      } else if (s == null && t == null) {
        bump('noAnchor');
      } else if (s == null || t == null) {
        bump('oneAnchorUnshipped');
      } else if (route.pointCount == 1) {
        bump('closeMissOnePoint');
      } else {
        final land = _openLanding(route, s)!;
        final miss = land.horizontal ? (land.y - t.y).abs() : (land.x - t.x).abs();
        bump(miss == 0 ? 'closeSignBad' : (miss <= 1 ? 'closeOff1' : 'closeMiss'));
        if (miss > 1) {
          final elongated = [w.endpointAttachRects[0], w.endpointAttachRects[1]].any((r) {
            if (r == null) return false;
            final w2 = r.right - r.left, h = r.bottom - r.top;
            final lo = w2 < h ? w2 : h, hi = w2 < h ? h : w2;
            return lo <= 9 && hi >= 2 * lo;
          });
          if (elongated) bump('closeMissElongated');
        }
      }

      if (s != null && t == null && route.direction != null) {
        final ep = d.byId[w.endpointOids[1]];
        final owner = ep == null ? null : _boundedOwner(d, ep);
        final land = owner == null ? null : _openLanding(route, s);
        if (ep != null && owner != null && land != null) {
          final box = owner.absBounds!;
          final kind = owner.kind == 0x2f ? 'p${owner.primResId}' : 'k${owner.kind.toRadixString(16)}';
          var ordinal = -1, count = 0;
          for (final child in d.children(owner.oid)) {
            if (kSignalEndpointDcoKinds.contains(child.kind)) {
              if (child.oid == ep.oid) ordinal = count;
              count++;
            }
          }
          final group =
              'L_${kind}_o${ordinal}of${count}_${box.right - box.left}x${box.bottom - box.top}_'
              '${land.horizontal ? (land.sign > 0 ? 'R' : 'L') : (land.sign > 0 ? 'D' : 'U')}';
          bump('$group=${land.horizontal ? land.y - box.top : land.x - box.left}');
        }
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
  bump('extDecoded');
  final eps = w.endpointOids.length;
  final modes = branch.modes;

  if (_bitCount(modes[0]) > 1) bump('extStartMask');
  for (var k = 1; k < modes.length; k++) {
    switch (WireRouteJunction.fromCode(modes[k])) {
      case WireRouteJunction.cross:
        bump('extJuncCross');
      case WireRouteJunction.downRight:
        bump('extJuncDownRight');
      case WireRouteJunction.upRight:
        bump('extJuncUpRight');
      case WireRouteJunction.upDown:
        bump('extJuncUpDown');
      case null:
        break;
    }
  }
  bump('extJuncSubst', _junctionSubstitutions(branch));
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
    bump('extEp0Unanchored');
    if ([for (var i = 1; i < eps; i++) attach[i]].any((p) => p != null)) bump('extRevAnchored');
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
      for (var i = 1; i < eps; i++) {
        if (attach[i] != null) continue;
        bump('extRevPlainLeaf');
        final box = w.endpointAnchors[i];
        if (box == null) continue;
        for (final leaf in pool) {
          if (leaf.x >= box.left - 8 && leaf.x <= box.right + 8 && leaf.y >= box.top - 8 && leaf.y <= box.bottom + 8) {
            bump('extRevPlainLeafInBox');
            pool.remove(leaf);
            break;
          }
        }
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
    bump('extLeafMismatch');
    return;
  }
  bool exact(int i) {
    final oid = w.endpointOids[i];
    final terminal = d.endpointTerminal(oid);
    if (terminal == null) return d.endpointConstantBounds(oid) == null;
    final parent = terminal.parentOid == null ? null : d.byId[terminal.parentOid!];
    final frame = parent == null ? null : _boundedOwner(d, parent);
    return frame != null && frame.category == ViObjectKind.structure;
  }

  final originExact = exact(0);
  final pool = List<ViPoint>.of(leaves);
  var anchored = 0, hits = 0;
  for (var i = 1; i < eps; i++) {
    final p = attach[i];
    if (p == null) continue;
    anchored++;
    final hit = hitOf(pool, i);
    if (hit) hits++;
    if (originExact && exact(i)) {
      bump('extEpExact');
      if (hit) {
        bump('extEpExactHit');
      } else {
        final rect = w.endpointAttachRects[i];
        final near = _nearestLeaf(leaves, p);
        final inRect =
            rect != null && near.x >= rect.left && near.x <= rect.right && near.y >= rect.top && near.y <= rect.bottom;
        bump(inRect ? 'extEpExactMissInRect' : 'extEpExactMissFar');
      }
    }
  }
  bump('extEpAnchored', anchored);
  bump('extEpHit', hits);
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

ViPoint _nearestLeaf(List<ViPoint> leaves, ViPoint p) {
  var best = leaves.first;
  var bestD = 1 << 30;
  for (final q in leaves) {
    final dist = (q.x - p.x).abs() + (q.y - p.y).abs();
    if (dist < bestD) {
      bestD = dist;
      best = q;
    }
  }
  return best;
}

int _bitCount(int v) => (v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1);

int _junctionSubstitutions(ViWireBranchRoute branch) {
  final modes = branch.modes;
  WireRouteDirection rev(WireRouteDirection dir) => switch (dir) {
    WireRouteDirection.up => WireRouteDirection.down,
    WireRouteDirection.down => WireRouteDirection.up,
    WireRouteDirection.left => WireRouteDirection.right,
    WireRouteDirection.right => WireRouteDirection.left,
  };
  final stack = <List<WireRouteDirection>>[];
  var subs = 0;
  WireRouteDirection? prev;
  for (var k = 0; k < modes.length; k++) {
    final m = modes[k];
    final WireRouteDirection dir;
    if (k == 0) {
      final oneHot = WireRouteDirection.fromCode(m);
      if (oneHot != null) {
        dir = oneHot;
      } else {
        final dirs = [
          for (final dd in WireRouteDirection.values)
            if (m & dd.code != 0) dd,
        ]..sort((a, b) => a.code.compareTo(b.code));
        dir = dirs.first;
        stack.add(dirs.sublist(1));
      }
    } else if (m == 0 || m == 1) {
      final positive = m == 0;
      dir = prev!.isHorizontal
          ? (positive ? WireRouteDirection.down : WireRouteDirection.up)
          : (positive ? WireRouteDirection.right : WireRouteDirection.left);
    } else if (m == ViWireBranchRoute.popCode) {
      while (stack.last.isEmpty) {
        stack.removeLast();
      }
      dir = stack.last.removeAt(0);
    } else {
      final blocked = rev(prev!);
      final dirs = [
        for (final dd in WireRouteJunction.fromCode(m)!.outgoing)
          if (dd == blocked) WireRouteDirection.left else dd,
      ];
      subs += WireRouteJunction.fromCode(m)!.outgoing.where((dd) => dd == blocked).length;
      dir = dirs.first;
      stack.add(dirs.sublist(1));
    }
    prev = dir;
  }
  return subs;
}

ViHeapObject? _boundedOwner(ViDiagram d, ViHeapObject ep) {
  ViHeapObject? cur = ep;
  final seen = <int>{};
  while (cur != null && seen.add(cur.oid)) {
    if (cur.absBounds != null) return cur;
    cur = cur.parentOid == null ? null : d.byId[cur.parentOid!];
  }
  return null;
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

Map<String, int> _foldLandings(Map<String, int> c) {
  final byGroup = <String, Map<int, int>>{};
  for (final e in c.entries.toList()) {
    if (!e.key.startsWith('L_')) continue;
    c.remove(e.key);
    final eq = e.key.lastIndexOf('=');
    final group = e.key.substring(0, eq);
    final offset = int.parse(e.key.substring(eq + 1));
    (byGroup[group] ??= {})[offset] = (byGroup[group]![offset] ?? 0) + e.value;
  }
  final out = <String, int>{};
  void tally(String prefix, bool Function(String) member) {
    var groups = 0, unanimous = 0, unanimousWeight = 0, majorityWeight = 0, total = 0;
    byGroup.forEach((g, dist) {
      if (!member(g)) return;
      groups++;
      final weight = dist.values.fold(0, (a, b) => a + b);
      final top = dist.values.reduce((a, b) => a > b ? a : b);
      total += weight;
      majorityWeight += top;
      if (dist.length == 1) {
        unanimous++;
        unanimousWeight += weight;
      }
    });
    out['${prefix}Groups'] = groups;
    out['${prefix}UnanimousGroups'] = unanimous;
    out['${prefix}UnanimousWeight'] = unanimousWeight;
    out['${prefix}MajorityWeight'] = majorityWeight;
    out['${prefix}Total'] = total;
  }

  tally('landing', (_) => true);
  tally('landingPrim', (g) => g.startsWith('L_p'));
  return out;
}

const _lawKeys = {
  'ext2ep',
  'shippedBad',
  'fidelityBad',
  'extFidelityBad',
  'bounded15Endpoints',
  'tables3Byte',
  'extUndecoded',
  'extJuncOffVertex',
};

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('wire route census (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  late final Map<String, int> C;
  setUpAll(() async {
    final res = await corpusParallel(all, _census);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
    C.addAll(_foldLandings(C));
  });

  test('wire route laws: no extended two-endpoint tables, shipped polylines anchored', () {
    expect(C['ext2ep'] ?? 0, 0, reason: 'the extended [n][00] form is multi-endpoint only');
    expect(
      C['shippedBad'] ?? 0,
      0,
      reason: 'every shipped polyline carries the stored point count and touches its anchor',
    );
    expect(C['fidelityBad'] ?? 0, 0, reason: 'every shipped polyline exposes a routePointsFidelity tier');
    expect(C['extFidelityBad'] ?? 0, 0, reason: 'routeTreeFidelity matches the anchoring (closed vs walked)');
    expect(C['bounded15Endpoints'] ?? 0, 0, reason: '0x15 node endpoints are bounds-less corpus-wide');
    expect(C['tables3Byte'] ?? 0, 0, reason: 'the grammar has no 3-byte table (u24 width unused)');
    expect(C['extUndecoded'] ?? 0, 0, reason: 'every extended branching table decodes and walks');
    expect(C['extJuncOffVertex'] ?? 0, 0, reason: 'every junction dot lies on a walked tree vertex');
    expect(
      C['extShippedClosed'] ?? 0,
      C['extFullClosed'] ?? 0,
      reason: 'the fully-anchored shipped trees are exactly the leaf-closing ones (closed tier)',
    );
    expect(
      C['extShipped'] ?? 0,
      (C['extShippedClosed'] ?? 0) +
          (C['extShippedWalked'] ?? 0) +
          (C['extShippedRev'] ?? 0) +
          (C['extShippedDcoClosed'] ?? 0),
      reason:
          'shipped branching trees partition into closed + walked + '
          'reverse-solved + DCO-child-closed tiers',
    );
    expect(
      C['shipped'] ?? 0,
      (C['shippedClosed'] ?? 0) +
          (C['shippedClosedDcoChild'] ?? 0) +
          (C['shippedWalkedFwd'] ?? 0) +
          (C['shippedWalkedRev'] ?? 0) +
          (C['shippedWalkedDcoRow'] ?? 0),
      reason:
          'shipped polylines partition into closed (standard + DCO-child '
          'fallback) + walked (forward/reverse/wide-row) tiers',
    );
    final juncSum =
        (C['extJuncCross'] ?? 0) +
        (C['extJuncDownRight'] ?? 0) +
        (C['extJuncUpRight'] ?? 0) +
        (C['extJuncUpDown'] ?? 0);
    expect(juncSum, 41304, reason: 'per-code junction segments sum to the corpus total');
    expect(
      (C['extFullClosed'] ?? 0) + (C['extFullMiss'] ?? 0) + (C['extFullLeafMismatch'] ?? 0),
      C['extFullAnchored'] ?? 0,
      reason: 'fully-anchored tables partition into closed / missed / leaf-mismatch',
    );
  });

  test('wire route census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_routes', {
      for (final e in C.entries)
        if (!_lawKeys.contains(e.key)) e.key: e.value,
    });
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
