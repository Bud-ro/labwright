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

enum _Axis {
  x,
  y
  ;

  int along(ViPoint point) => this == x ? point.x : point.y;

  int cross(ViPoint point) => this == x ? point.y : point.x;

  int alongLow(HeapRect box) => this == x ? box.left : box.top;

  int alongHigh(HeapRect box) => this == x ? box.right : box.bottom;

  int crossLow(HeapRect box) => this == x ? box.top : box.left;

  int crossHigh(HeapRect box) => this == x ? box.bottom : box.right;

  bool alongInside(HeapRect box, int along) => along >= alongLow(box) && along < alongHigh(box);

  bool crossInside(HeapRect box, int cross) => cross >= crossLow(box) && cross < crossHigh(box);

  ViPoint point({required int along, required int cross}) => this == x ? (x: along, y: cross) : (x: cross, y: along);

  ViStep step(int sign) => this == x ? (dx: sign, dy: 0) : (dx: 0, dy: sign);
}

({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? walkOneAnchoredRoute(
  ViWireRoute route, {
  required ViPoint anchor,
  required int anchoredIndex,
  required HeapRect farBox,
}) {
  if (route.pointCount < 2) return null;
  return anchoredIndex == 0
      ? _walkFromAnchor(route, anchor: anchor, farBox: farBox)
      : _walkIntoAnchor(route, anchor: anchor, farBox: farBox);
}

({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? _walkFromAnchor(
  ViWireRoute route, {
  required ViPoint anchor,
  required HeapRect farBox,
}) {
  final walk = walkRouteBends(route, origin: anchor);
  if (walk == null) return null;
  final points = walk.points;
  final closingSign = walk.closingSign;
  final tail = points.last;
  final axis = walk.closingHorizontal ? _Axis.x : _Axis.y;
  if (!axis.crossInside(farBox, axis.cross(tail))) return null;
  final nearEdge = closingSign > 0 ? axis.alongLow(farBox) : axis.alongHigh(farBox) - 1;
  if ((nearEdge - axis.along(tail)) * closingSign < 0) {
    final ahead = axis.along(tail) + closingSign;
    if (points.length < 2 || !axis.alongInside(farBox, axis.along(tail)) || !axis.alongInside(farBox, ahead)) {
      return null;
    }
    return (points: points, closingStep: axis.step(closingSign), headSlack: null);
  }
  final terminus = axis.point(along: nearEdge, cross: axis.cross(tail));
  if (terminus != tail) points.add(terminus);
  return (points: points, closingStep: null, headSlack: null);
}

({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack})? _walkIntoAnchor(
  ViWireRoute route, {
  required ViPoint anchor,
  required HeapRect farBox,
}) {
  final walk = walkRouteBends(route);
  if (walk == null) return null;
  final local = walk.points;
  final lastBend = local.last;
  final closingSign = walk.closingSign;
  final headSign = walk.direction.dx + walk.direction.dy;
  if (walk.direction.isHorizontal != walk.closingHorizontal) return null;
  final axis = walk.closingHorizontal ? _Axis.x : _Axis.y;
  final crossShift = axis.cross(anchor) - axis.cross(lastBend);
  if (!axis.crossInside(farBox, crossShift)) return null;
  final alongShift = headSign > 0 ? axis.alongHigh(farBox) - 1 : axis.alongLow(farBox);
  final shift = axis.point(along: alongShift, cross: crossShift);
  final points = [for (final point in local) (x: point.x + shift.x, y: point.y + shift.y)];
  final tail = points.last;
  if (axis.cross(tail) != axis.cross(anchor) || (axis.along(anchor) - axis.along(tail)) * closingSign < 0) {
    return null;
  }
  final headSlack = route.segmentLengths.isEmpty ? null : axis.step(-headSign);
  if (anchor != tail || headSlack != null) points.add(anchor);
  return (points: points, closingStep: null, headSlack: headSlack);
}
