import 'dart:typed_data';

import 'diagram_object.dart';
import 'heap.dart';
import 'signal_type.dart';

enum WireRouteFidelity {
  closed,

  walked,
}

class ViWire {
  ViWire({
    required this.signalOid,
    required this.endpointOids,
    required this.endpointAnchors,
    List<HeapRect?>? endpointAttachRects,
    this.route,
    this.routePoints,
    this.routePointsFidelity,
    this.routeClosingStep,
    this.routeHeadSlack,
    this.branchRoute,
    ViWireRouteTree? routeTree,
    WireRouteFidelity? routeTreeFidelity,
    ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? routeTreeBuilder,
    this.signalType,
  }) : endpointAttachRects = endpointAttachRects ?? List<HeapRect?>.filled(endpointOids.length, null),
       _routeTree = routeTree,
       _directRouteTreeFidelity = routeTreeFidelity,
       _routeTreeBuilder = routeTreeBuilder;

  final ViWireRouteTree? _routeTree;
  final WireRouteFidelity? _directRouteTreeFidelity;
  final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? Function()? _routeTreeBuilder;

  final int signalOid;

  final List<int> endpointOids;

  final List<HeapRect?> endpointAnchors;

  final List<HeapRect?> endpointAttachRects;

  final ViWireRoute? route;

  final ViWireBranchRoute? branchRoute;

  late final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _routeTreeResult = _routeTreeBuilder?.call();
  late final ViWireRouteTree? routeTree = _routeTree ?? _routeTreeResult?.tree;

  late final WireRouteFidelity? routeTreeFidelity = routeTree == null
      ? null
      : (_routeTree != null ? _directRouteTreeFidelity : _routeTreeResult?.fidelity);

  final List<ViPoint>? routePoints;

  final WireRouteFidelity? routePointsFidelity;

  final ViStep? routeClosingStep;

  final ViStep? routeHeadSlack;

  final ViSignalType? signalType;

  ViTypeKind? get typeKind => signalType?.typeKind;

  ViTypeKind? get elementTypeKind => signalType?.elementKind;
}

typedef ViPoint = ({int x, int y});

typedef ViStep = ({int dx, int dy});

enum WireRouteDirection {
  up(0x01, 0, -1),

  left(0x02, -1, 0),

  down(0x04, 0, 1),

  right(0x08, 1, 0)
  ;

  const WireRouteDirection(this.code, this.dx, this.dy);

  final int code;

  final int dx;

  final int dy;

  bool get isHorizontal => dy == 0;

  static final Map<int, WireRouteDirection> _byCode = {
    for (final value in values) value.code: value,
  };

  static WireRouteDirection? fromCode(int code) => _byCode[code];
}

class ViWireRoute {
  ViWireRoute({
    required this.pointCount,
    this.direction = WireRouteDirection.right,
    required this.segmentLengths,
    required this.jointSigns,
  });

  final int pointCount;

  final WireRouteDirection? direction;

  final List<int> segmentLengths;

  final List<int> jointSigns;
}

List<int>? _decodeLengthTail(Uint8List table, int start) {
  var i = start;
  final lengths = <int>[];
  while (i < table.length) {
    var value = table[i++];
    if (value == 0xff) {
      if (i + 1 >= table.length) return null;
      value = (table[i] << 8) | table[i + 1];
      i += 2;
    }
    lengths.add(value);
  }
  return lengths;
}

// TODO: a residue of two-endpoint tables opening with the up code carries two trailing bytes this grammar does not explain.
ViWireRoute? decodeWireRoute(Uint8List table) {
  if (table.isEmpty) return null;
  final n = table[0];
  if (n == 1) {
    if (table.length != 1) return null;
    return ViWireRoute(pointCount: 1, direction: null, segmentLengths: const [], jointSigns: const []);
  }
  if (n < 2 || table.length < 2) return null;
  final direction = WireRouteDirection.fromCode(table[1]);
  if (direction == null) return null;
  var i = 2;
  final signs = <int>[];
  for (var k = 0; k < n - 2; k++) {
    if (i >= table.length) return null;
    final m = table[i++];
    if (m != 0 && m != 1) return null;
    signs.add(m == 0 ? 1 : -1);
  }
  final lengths = _decodeLengthTail(table, i);
  if (lengths == null) return null;
  if (lengths.length != n - 2) return null;
  return ViWireRoute(pointCount: n, direction: direction, segmentLengths: lengths, jointSigns: signs);
}

enum WireRouteJunction {
  cross(0x04, [WireRouteDirection.up, WireRouteDirection.down, WireRouteDirection.right]),

  downRight(0x05, [WireRouteDirection.down, WireRouteDirection.right]),

  upRight(0x06, [WireRouteDirection.up, WireRouteDirection.right]),

  upDown(0x07, [WireRouteDirection.up, WireRouteDirection.down])
  ;

  const WireRouteJunction(this.code, this.outgoing);

  final int code;

  final List<WireRouteDirection> outgoing;

  static final Map<int, WireRouteJunction> _byCode = {
    for (final value in values) value.code: value,
  };

  static WireRouteJunction? fromCode(int code) => _byCode[code];
}

class ViWireBranchRoute {
  ViWireBranchRoute._({required this.pointCount, required this.modes, required this.segmentLengths});

  static const int popCode = 0x03;

  final int pointCount;

  final Uint8List modes;

  final List<int> segmentLengths;
}

ViWireBranchRoute? decodeWireBranchRoute(Uint8List table) {
  if (table.length < 2 || table[1] != 0) return null;
  final n = table[0];
  if (n < 2 || table.length < 1 + n) return null;
  final modes = Uint8List.sublistView(table, 2, 1 + n);
  final first = modes[0];
  if (first == 0 || first > 0x0f) return null;
  var pending = _bitCount(first) - 1;
  for (var k = 1; k < modes.length; k++) {
    final m = modes[k];
    if (m == 0 || m == 1) continue;
    if (m == ViWireBranchRoute.popCode) {
      if (pending == 0) return null;
      pending--;
      continue;
    }
    final junction = WireRouteJunction.fromCode(m);
    if (junction == null) return null;
    pending += junction.outgoing.length - 1;
  }
  if (pending != 0) return null;
  final lengths = _decodeLengthTail(table, 1 + n);
  if (lengths == null || lengths.length != n - 1) return null;
  return ViWireBranchRoute._(pointCount: n, modes: modes, segmentLengths: lengths);
}

int _bitCount(int v) => (v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1);

class ViWireRouteTree {
  ViWireRouteTree({required this.polylines, required this.junctions});

  final List<List<ViPoint>> polylines;

  final List<ViPoint> junctions;

  late final List<ViPoint> leaves = [for (final polyline in polylines) polyline.last];
}

ViWireRouteTree walkWireBranchRoute(ViWireBranchRoute route, ViPoint start) {
  final modes = route.modes;
  final lengths = route.segmentLengths;
  final polylines = <List<ViPoint>>[];
  final junctionPoints = <ViPoint>[];
  final stack = <(ViPoint, List<WireRouteDirection>)>[];
  var run = <ViPoint>[start];
  var pos = start;
  WireRouteDirection? prev;
  for (var k = 0; k < modes.length; k++) {
    final m = modes[k];
    final WireRouteDirection direction;
    if (k == 0) {
      final oneHot = WireRouteDirection.fromCode(m);
      if (oneHot != null) {
        direction = oneHot;
      } else {
        final dirs = [
          for (final d in WireRouteDirection.values)
            if (m & d.code != 0) d,
        ]..sort((a, b) => a.code.compareTo(b.code));
        direction = dirs.first;
        stack.add((pos, dirs.sublist(1)));
        junctionPoints.add(pos);
      }
    } else if (m == 0 || m == 1) {
      final positive = m == 0;
      direction = prev!.isHorizontal
          ? (positive ? WireRouteDirection.down : WireRouteDirection.up)
          : (positive ? WireRouteDirection.right : WireRouteDirection.left);
    } else if (m == ViWireBranchRoute.popCode) {
      polylines.add(run);
      while (stack.last.$2.isEmpty) {
        stack.removeLast();
      }
      final (jpos, dirs) = stack.last;
      pos = jpos;
      run = <ViPoint>[pos];
      direction = dirs.removeAt(0);
    } else {
      final blocked = _reverse(prev!);
      final dirs = [
        for (final d in WireRouteJunction.fromCode(m)!.outgoing) d == blocked ? WireRouteDirection.left : d,
      ];
      direction = dirs.first;
      stack.add((pos, dirs.sublist(1)));
      junctionPoints.add(pos);
    }
    pos = (x: pos.x + direction.dx * lengths[k], y: pos.y + direction.dy * lengths[k]);
    run.add(pos);
    prev = direction;
  }
  polylines.add(run);
  return ViWireRouteTree(polylines: polylines, junctions: junctionPoints);
}

WireRouteDirection _reverse(WireRouteDirection d) => switch (d) {
  WireRouteDirection.up => WireRouteDirection.down,
  WireRouteDirection.down => WireRouteDirection.up,
  WireRouteDirection.left => WireRouteDirection.right,
  WireRouteDirection.right => WireRouteDirection.left,
};

({List<ViPoint> points, WireRouteDirection direction, bool closingHorizontal, int closingSign})? walkRouteBends(
  ViWireRoute route, {
  ViPoint origin = (x: 0, y: 0),
}) {
  final direction = route.direction;
  if (direction == null) return null;
  var x = origin.x, y = origin.y;
  var horizontal = direction.isHorizontal;
  var sign = direction.dx + direction.dy;
  final lengths = route.segmentLengths;
  final points = <ViPoint>[origin];
  for (var k = 0; k < lengths.length; k++) {
    if (k > 0) sign = route.jointSigns[k - 1];
    if (horizontal) {
      x += lengths[k] * sign;
    } else {
      y += lengths[k] * sign;
    }
    points.add((x: x, y: y));
    horizontal = !horizontal;
  }
  return (
    points: points,
    direction: direction,
    closingHorizontal: horizontal,
    closingSign: route.jointSigns.isEmpty ? direction.dx + direction.dy : route.jointSigns.last,
  );
}

({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? walkOneAnchoredRoute(
  ViWireRoute route, {
  required ViPoint anchor,
  required int anchoredIndex,
  required HeapRect farBox,
}) {
  if (route.pointCount < 2) return null;

  if (anchoredIndex == 0) {
    final walk = walkRouteBends(route, origin: anchor);
    if (walk == null) return null;
    final pts = walk.points;
    final closingSign = walk.closingSign;
    final tail = pts.last;
    final ViPoint terminus;
    if (walk.closingHorizontal) {
      if (tail.y < farBox.top || tail.y >= farBox.bottom) return null;
      final tx = closingSign > 0 ? farBox.left : farBox.right - 1;
      if ((tx - tail.x) * closingSign < 0) {
        final ahead = tail.x + closingSign;
        if (pts.length < 2 ||
            tail.x < farBox.left ||
            tail.x >= farBox.right ||
            ahead < farBox.left ||
            ahead >= farBox.right) {
          return null;
        }
        return (points: pts, closingStep: (dx: closingSign, dy: 0), headSlack: null);
      }
      terminus = (x: tx, y: tail.y);
    } else {
      if (tail.x < farBox.left || tail.x >= farBox.right) return null;
      final ty = closingSign > 0 ? farBox.top : farBox.bottom - 1;
      if ((ty - tail.y) * closingSign < 0) {
        final ahead = tail.y + closingSign;
        if (pts.length < 2 ||
            tail.y < farBox.top ||
            tail.y >= farBox.bottom ||
            ahead < farBox.top ||
            ahead >= farBox.bottom) {
          return null;
        }
        return (points: pts, closingStep: (dx: 0, dy: closingSign), headSlack: null);
      }
      terminus = (x: tail.x, y: ty);
    }
    if (terminus != tail) pts.add(terminus);
    return (points: pts, closingStep: null, headSlack: null);
  }

  final walk = walkRouteBends(route);
  if (walk == null) return null;
  final local = walk.points;
  final lastBend = local.last;
  final closingHorizontal = walk.closingHorizontal;
  final closingSign = walk.closingSign;
  final seg0Sign = walk.direction.dx + walk.direction.dy;
  if (walk.direction.isHorizontal != closingHorizontal) return null;
  final int tx, ty;
  if (closingHorizontal) {
    ty = anchor.y - lastBend.y;
    if (ty < farBox.top || ty >= farBox.bottom) return null;
    tx = seg0Sign > 0 ? farBox.right - 1 : farBox.left;
  } else {
    tx = anchor.x - lastBend.x;
    if (tx < farBox.left || tx >= farBox.right) return null;
    ty = seg0Sign > 0 ? farBox.bottom - 1 : farBox.top;
  }
  final pts = [for (final p in local) (x: p.x + tx, y: p.y + ty)];
  final tail = pts.last;
  if (closingHorizontal) {
    if (tail.y != anchor.y || (anchor.x - tail.x) * closingSign < 0) return null;
  } else {
    if (tail.x != anchor.x || (anchor.y - tail.y) * closingSign < 0) return null;
  }
  final headSlack = route.segmentLengths.isEmpty
      ? null
      : closingHorizontal
      ? (dx: -seg0Sign, dy: 0)
      : (dx: 0, dy: -seg0Sign);
  if (anchor != tail || headSlack != null) pts.add(anchor);
  return (points: pts, closingStep: null, headSlack: headSlack);
}
