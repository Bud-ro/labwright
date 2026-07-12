@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the stored wire-route decode ([ViWireRoute] /
/// [ViWire.routePoints]) — every number the doc comments cite, recomputed
/// from scratch and asserted exactly against the `wire_routes` snapshot
/// section. One extra full-model corpus pass.
///
/// Four censuses share the pass:
///
///  1. **Table forms** — per two-endpoint signal: which direction code the
///     table opens with, the undecoded residue, and the multi-endpoint
///     (extended `[n][00]…`) population.
///  2. **Closure outcomes** — for every two-endpoint signal whose BOTH
///     endpoints resolve a [ViDiagram.wireAttachPoint], whether the walked
///     route closes exactly (ships [ViWire.routePoints]) or how it fails.
///     Failures are never force-closed, so the miss buckets stay visible.
///  3. **Branching routes** — per 3+-endpoint extended table: decode/walk
///     totality, leaf closure onto the anchored attach points, the
///     fully-anchored split gating [ViWire.routeTree], and the
///     exact-attach-geometry subset (see [_extCensus]).
///  4. **Plain-node landings** — for wires walkable from one anchored end
///     whose far endpoint is a plain-node DCO (no attach geometry), the
///     walked landing coordinate relative to the owner node's box, grouped
///     by (node kind / primResID, endpoint ordinal, box size, approach).
///     Only the unanimity SUMMARY is pinned: the groups are dominated by a
///     single landing value but are NOT unanimous (rare stale-route
///     outliers), so no placement table is shipped — the walked polyline
///     ([ViWire.routePoints], its far end derived from the owner box) stands
///     alone. TODO: revisit a placement table once the outliers are separable
///     (e.g. by a staleness signal).
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
      // Law: the 0x15 node endpoints are bounds-less (the own-bounds attach
      // fallback belongs to 0x16 alone).
      for (final oid in w.endpointOids) {
        final ep = d.byId[oid];
        if (ep != null && ep.kind == 0x15 && ep.absBounds != null) bump('bounded15Endpoints');
      }
      if (raw == null) {
        bump(eps == 2 ? 'noTable2ep' : 'noTableMulti');
        continue;
      }
      // Law: the grammar has no 3-byte table, so the u24 capture width is
      // never exercised.
      if (raw.length == 3) bump('tables3Byte');
      if (eps != 2) {
        final ext = raw.length >= 2 && raw[1] == 0;
        bump(ext ? 'multiExtTable' : 'multiShortTable');
        // The extended form on a degenerate <3-endpoint signal: counted here
        // so multiExtTable (all eps != 2) reconciles with the eps >= 3
        // branch census (extDecoded) — the gap is `multiExtTableSub3`.
        if (ext && eps < 3) bump('multiExtTableSub3');
        if (ext && eps >= 3) _extCensus(d, w, bump);
        continue;
      }
      bump('tables2ep');
      if (raw.length >= 2 && raw[1] == 0) bump('ext2ep'); // law: 0
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
      final points = w.routePoints;
      if (points != null) {
        bump('shipped');
        // Tier split: both endpoints resolve = the proven closed polyline;
        // exactly one resolves = the one-anchored walked polyline (forward
        // from endpoint 0, or reverse from an endpoint-1 anchor on a straight
        // route). See [ViWire.routePoints].
        final walked = s == null || t == null;
        if (!walked) {
          bump('shippedClosed');
        } else {
          bump(s != null ? 'shippedWalkedFwd' : 'shippedWalkedRev');
        }
        // Law: the exposed fidelity tier matches the anchoring (closed iff both
        // ends resolve, walked otherwise).
        final wantFid = walked ? WireRouteFidelity.walked : WireRouteFidelity.closed;
        if (w.routePointsFidelity != wantFid) bump('fidelityBad');
        // A forward walk whose last decoded bend enters the far node ships the
        // polyline to that bend (pointCount-1 points) with an into-node closing
        // step; the length that would carry it to the node's connection is the
        // undecoded input-pin depth. Counted apart from a genuine zero-length
        // closing run.
        if (w.routeClosingStep != null) {
          bump('shippedWalkedIntoNode');
        } else if (points.length == route.pointCount - 1) {
          // A zero-length closing/derived run ships pointCount-1 points (the
          // walk ends ON the far point; no duplicate terminal vertex). Its
          // stored closing sign is uncheckable — census its split anyway.
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
        // Law: a shipped polyline carries the stored point count (one fewer
        // for a zero run) and touches its anchor(s) — both attach points when
        // closed, else the sole resolved end (leading for a forward walk,
        // trailing for a reverse walk).
        final lenOk = points.length == route.pointCount || points.length == route.pointCount - 1;
        final bool anchorOk;
        if (!walked) {
          anchorOk = points.first == s && points.last == t;
        } else if (s != null) {
          anchorOk = points.first == s;
        } else {
          anchorOk = points.last == t;
        }
        if (!lenOk || !anchorOk) bump('shippedBad');
      } else if (s == null && t == null) {
        bump('noAnchor');
      } else if (s == null || t == null) {
        bump('oneAnchorUnshipped');
      } else if (route.pointCount == 1) {
        bump('closeMissOnePoint'); // 1-point table, endpoints do not coincide
      } else {
        final land = _openLanding(route, s)!;
        final miss = land.horizontal ? (land.y - t.y).abs() : (land.x - t.x).abs();
        bump(miss == 0 ? 'closeSignBad' : (miss <= 1 ? 'closeOff1' : 'closeMiss'));
        if (miss > 1) {
          // How many misses press against an elongated attach rect (a grown
          // border-terminal stack: narrow dimension ≤ 9, other ≥ 2×).
          final elongated = [w.endpointAttachRects[0], w.endpointAttachRects[1]].any((r) {
            if (r == null) return false;
            final w2 = r.right - r.left, h = r.bottom - r.top;
            final lo = w2 < h ? w2 : h, hi = w2 < h ? h : w2;
            return lo <= 9 && hi >= 2 * lo;
          });
          if (elongated) bump('closeMissElongated');
        }
      }

      // Landing census: anchored start, plain-node far endpoint.
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

/// The extended (branching) route census for one 3+-endpoint signal whose
/// table opens `[n][00]`. Structural (no anchoring): per-code junction
/// segments (`extJunc*`), start-mask population (`extStartMask`), the
/// substitution count (`extJuncSubst`), and the leaf-count law
/// `#pop + 2 == endpoint count` (`extLeafLawViol`). Origin-anchored:
/// the walk, the junction-on-vertex interior law (`extJuncOffVertex`),
/// per-endpoint leaf closure onto the attach points (greedy multiset
/// matching), and the fully-anchored split that gates [ViWire.routeTree].
///
/// The **exact-attach subset** (`extEpExact` / `extEpExactHit`) isolates
/// the walk rule from attach-point error: an endpoint counts as exact when
/// its attach geometry is border-exact — anchored on its own `0x16` bounds
/// (no terminal, no constant shell), or resolving a terminal whose REAL
/// composing frame (the nearest BOUNDED ancestor of the terminal's parent,
/// matching how [ViDiagram.endpointTerminalBounds] composes) is a structure.
/// Node-framed rects and constant value-shell centres (both approximate) are
/// excluded. Both origin and endpoint must be exact. Exact-subset misses are
/// partitioned into `extEpExactMissInRect`
/// (the nearest walked leaf still lands inside the endpoint's own attach
/// rect — right terminal, off the floored-centre convention) and
/// `extEpExactMissFar`.
void _extCensus(ViDiagram d, ViWire w, void Function(String, [int]) bump) {
  final branch = w.branchRoute;
  if (branch == null) {
    bump('extUndecoded'); // law: 0 — every extended table decodes
    return;
  }
  bump('extDecoded');
  final eps = w.endpointOids.length;
  final modes = branch.modes;

  // Structural census (no attach anchoring needed).
  // Per-code junction segments + start-mask population.
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
  // Leaf-count law over ALL tables: endpoint count == #pop + 2. The first
  // mode is never a pop (it is a direction or start mask — a 0x03 there is
  // the up|left mask), so pops are counted from mode 1.
  final pops = modes.skip(1).where((m) => m == ViWireBranchRoute.popCode).length;
  if (pops + 2 != eps) bump('extLeafLawViol');
  // Fully-anchored accounting (independent of the walk): every endpoint has
  // an attach point.
  final attach = [for (final oid in w.endpointOids) d.wireAttachPoint(oid)];
  final fullyAnchored = attach.every((p) => p != null);
  if (fullyAnchored) {
    bump('extFullAnchored');
    if (pops + 2 != eps) bump('extFullLeafMismatch');
  }

  final origin = attach[0];
  if (origin == null) {
    bump('extEp0Unanchored');
    return;
  }
  final tree = walkWireBranchRoute(branch, origin);
  // Interior law: every junction dot lies on a walked vertex of the tree.
  final vertices = {for (final line in tree.polylines) ...line};
  for (final j in tree.junctions) {
    if (!vertices.contains(j)) bump('extJuncOffVertex'); // law: 0
  }
  final leaves = tree.leaves;
  if (leaves.length != eps - 1) {
    bump('extLeafMismatch'); // origin-anchored subset of extLeafLawViol
    return;
  }
  // Exact attach geometry: the endpoint resolves a structure-framed rect via
  // its REAL composing frame (endpointTerminalBounds composes against the
  // nearest BOUNDED ancestor of the terminal's parent), or is anchored on
  // its own `0x16` bounds (no terminal, no constant shell). Node-framed
  // rects AND constant value-shell centres are approximate — the wire leaves
  // a constant at its edge, not the shell centre — and are excluded.
  bool exact(int i) {
    final oid = w.endpointOids[i];
    final terminal = d.endpointTerminal(oid);
    if (terminal == null) return d.endpointConstantBounds(oid) == null; // 0x16 own-bounds only
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
    final hit = pool.remove(p);
    if (hit) hits++;
    if (originExact && exact(i)) {
      bump('extEpExact');
      if (hit) {
        bump('extEpExactHit');
      } else {
        // Miss partition: does the nearest walked leaf land inside this
        // endpoint's own attach rect (right terminal, off the floored
        // centre) or genuinely far?
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
  // Tier split: a fully-anchored shipped tree is the proven closed tier (law:
  // == extFullClosed); a shipped tree with a plain-node leaf is the walked
  // tier (origin-anchored, contradiction-free — see [ViWire.routeTree]).
  if (w.routeTree != null) {
    bump('extShipped');
    bump(fullyAnchored ? 'extShippedClosed' : 'extShippedWalked');
    // Law: the exposed tree fidelity matches the anchoring.
    if (w.routeTreeFidelity != (fullyAnchored ? WireRouteFidelity.closed : WireRouteFidelity.walked)) {
      bump('extFidelityBad');
    }
  }
}

/// The walked leaf nearest [p] (Manhattan) — for the exact-subset miss
/// partition.
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

/// Set-bit count of a mode byte (masks are ≤ 4 bits).
int _bitCount(int v) => (v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1);

/// The number of junction outgoing directions the branch walk SUBSTITUTES to
/// [WireRouteDirection.left] because the catalog direction would reverse the
/// incoming edge — a direction-only replay (positions are irrelevant to the
/// substitution). Independent re-derivation of the rule shipped in
/// [walkWireBranchRoute], pinned as `extJuncSubst`.
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

/// The owner node whose box the plain-node landing is measured against —
/// the endpoint itself if bounded, else its nearest bounded ancestor.
ViHeapObject? _boundedOwner(ViDiagram d, ViHeapObject ep) {
  ViHeapObject? cur = ep;
  final seen = <int>{};
  while (cur != null && seen.add(cur.oid)) {
    if (cur.absBounds != null) return cur;
    cur = cur.parentOid == null ? null : d.byId[cur.parentOid!];
  }
  return null;
}

/// Walks the stored segments from [s] without closing: the position after
/// the last stored segment, the closing segment's axis, and its stored sign.
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

/// Folds the raw `L_<group>=<offset>` landing keys into the pinned summary:
/// group counts, unanimous coverage, and majority coverage — overall and for
/// the primitive-owned (`L_p…`) subset.
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
    expect(C['fidelityBad'] ?? 0, 0, reason: 'routePointsFidelity matches the anchoring (closed vs walked)');
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
      (C['extShippedClosed'] ?? 0) + (C['extShippedWalked'] ?? 0),
      reason: 'shipped branching trees partition into closed + walked tiers',
    );
    expect(
      C['shipped'] ?? 0,
      (C['shippedClosed'] ?? 0) + (C['shippedWalkedFwd'] ?? 0) + (C['shippedWalkedRev'] ?? 0),
      reason: 'shipped polylines partition into closed + walked (forward/reverse) tiers',
    );
    // Junction-segment totals reconcile two ways (per-code sum == 41,304).
    final juncSum =
        (C['extJuncCross'] ?? 0) +
        (C['extJuncDownRight'] ?? 0) +
        (C['extJuncUpRight'] ?? 0) +
        (C['extJuncUpDown'] ?? 0);
    expect(juncSum, 41304, reason: 'per-code junction segments sum to the corpus total');
    // Fully-anchored accounting: 1,859 = closed + missed + leaf-mismatch.
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
    // The snippet's raster is LabVIEW's own render of the embedded VI (see
    // png_snippet.dart): terminal boxes (58,1)-(90,17) / (58,35)-(90,51),
    // the add primitive at (106,10)-(138,42), bend column drawn at
    // x=102-103, input rows drawn at y=21 / y=31.
    final candidates = corpusViDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.replaceAll(r'\', '/').endsWith('/Snippets/basic.png'))
        .toList();
    expect(candidates, hasLength(1));
    final vi = extractSnippetVi(candidates.single.readAsBytesSync())!;
    final d = buildViModelFromDecoded(decodeSections(vi)).blockDiagrams.single;
    // Select the two routed wires by their source terminal's attach point
    // (the 32x16 boxes' floored centres).
    ViWire wireAt(ViPoint p) => d.wires.singleWhere((w) => d.wireAttachPoint(w.endpointOids[0]) == p);
    final x = wireAt((x: 74, y: 9)), y = wireAt((x: 74, y: 43));
    expect(x.route!.direction, WireRouteDirection.right);
    expect(x.route!.segmentLengths, [28, 12]);
    expect(x.route!.jointSigns, [1, 1]);
    expect(y.route!.jointSigns, [-1, 1]);
    // The walked bends land on the drawn bend column and input rows.
    final landX = _openLanding(x.route!, (x: 74, y: 9))!;
    expect((landX.x, landX.y, landX.horizontal, landX.sign), (102, 21, true, 1));
    final landY = _openLanding(y.route!, (x: 74, y: 43))!;
    expect((landY.x, landY.y), (102, 31));
    // The x wire's far endpoint is a plain-node DCO (the add input): it
    // resolves no attach point, so the closed polyline cannot ship. The
    // one-anchored walked tier does — the source terminal is an exact anchor,
    // so the polyline walks the stored bends and lands the plain-node terminus
    // on the add primitive's left edge (x=106) at the drawn input row (y=21).
    expect(d.wireAttachPoint(x.endpointOids[1]), isNull);
    expect(x.routePoints, [(x: 74, y: 9), (x: 102, y: 9), (x: 102, y: 21), (x: 106, y: 21)]);
    // The third wire (add output -> indicator terminal) stored the trivial
    // straight table.
    final straight = d.wires.singleWhere((w) => w.signalOid != x.signalOid && w.signalOid != y.signalOid);
    expect((straight.route!.pointCount, straight.route!.direction), (2, WireRouteDirection.right));
  });
}
