@Tags(['corpus'])
library;

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
/// Three censuses share the pass:
///
///  1. **Table forms** — per two-endpoint signal: which direction code the
///     table opens with, the undecoded residue, and the multi-endpoint
///     (extended `[n][00]…`) population.
///  2. **Closure outcomes** — for every two-endpoint signal whose BOTH
///     endpoints resolve a [ViDiagram.wireAttachPoint], whether the walked
///     route closes exactly (ships [ViWire.routePoints]) or how it fails.
///     Failures are never force-closed, so the miss buckets stay visible.
///  3. **Plain-node landings** — for wires walkable from one anchored end
///     whose far endpoint is a plain-node DCO (no attach geometry), the
///     walked landing coordinate relative to the owner node's box, grouped
///     by (node kind / primResID, endpoint ordinal, box size, approach).
///     Only the unanimity SUMMARY is pinned: the groups are dominated by a
///     single landing value but are NOT unanimous (rare stale-route
///     outliers), so no placement table is shipped — the absolute routes
///     stand alone. TODO: revisit a placement table once the outliers are
///     separable (e.g. by a staleness signal).
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
      if (raw == null) {
        bump(eps == 2 ? 'noTable2ep' : 'noTableMulti');
        continue;
      }
      if (eps != 2) {
        bump(raw.length >= 2 && raw[1] == 0 ? 'multiExtTable' : 'multiShortTable');
        continue;
      }
      bump('tables2ep');
      if (raw.length >= 2 && raw[1] == 0) bump('ext2ep'); // law: 0
      final route = w.route;
      if (route == null) {
        bump('undecoded2ep');
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
        // Law: a shipped polyline is anchored at both attach points and
        // carries exactly the stored point count.
        if (points.length != route.pointCount || points.first != s || points.last != t) {
          bump('shippedBad');
        }
      } else if (s == null && t == null) {
        bump('noAnchor');
      } else if (s == null || t == null) {
        bump('oneAnchor');
      } else if (route.pointCount == 1) {
        bump('closeMiss'); // 1-point table whose endpoints do not coincide
      } else {
        final land = _openLanding(route, s);
        if (land == null) {
          bump('closeMalformed');
        } else {
          final miss = land.horizontal ? (land.y - t.y).abs() : (land.x - t.x).abs();
          bump(miss == 0 ? 'closeSignBad' : (miss <= 1 ? 'closeOff1' : 'closeMiss'));
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

const _lawKeys = {'ext2ep', 'shippedBad', 'closeMalformed'};

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
    expect(C['shippedBad'] ?? 0, 0, reason: 'every shipped polyline spans attach point to attach point');
    expect(C['closeMalformed'] ?? 0, 0, reason: 'a decoded route always walks');
  });

  test('wire route census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('wire_routes', {
      for (final e in C.entries)
        if (!_lawKeys.contains(e.key)) e.key: e.value,
    });
  });
}
