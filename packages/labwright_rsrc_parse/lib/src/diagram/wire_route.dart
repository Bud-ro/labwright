/// Wires and their routes: [ViWire] carries a wire's endpoints, anchors and route;
/// [ViWireRoute] and [ViWireBranchRoute] are the decoded route tables and [ViWireRouteTree] the
/// corners walked from an anchored endpoint.
library;

import 'dart:typed_data';

import '../heap/heap.dart';
import 'objects.dart';

/// How a decoded route was placed on the diagram.
enum WireRouteFidelity {
  /// The walk from one endpoint's attach point lands exactly on the other's.
  closed,

  /// The walk is anchored at one endpoint and ends inside the other's box.
  walked,
}

/// One `signal` object of a block diagram as a wire: its endpoints, where each attaches, and
/// its route in diagram pixels. The endpoint at index 0 is where the route table starts.
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

  /// The signal's `childRef` targets, in record order.
  final List<int> endpointOids;

  /// Per endpoint, the constant's bounds or the nearest bounded ancestor's; null when none.
  final List<HeapRect?> endpointAnchors;

  /// Per endpoint, the terminal's absolute `termBounds`, else the constant's bounds.
  final List<HeapRect?> endpointAttachRects;

  /// The decoded route table of a two-endpoint wire.
  final ViWireRoute? route;

  /// The decoded route table of a wire with three or more endpoints.
  final ViWireBranchRoute? branchRoute;

  late final ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _routeTreeResult = _routeTreeBuilder?.call();

  /// [branchRoute] walked from a solved origin; null when no origin closes it.
  late final ViWireRouteTree? routeTree = _routeTree ?? _routeTreeResult?.tree;

  late final WireRouteFidelity? routeTreeFidelity = routeTree == null
      ? null
      : (_routeTree != null ? _directRouteTreeFidelity : _routeTreeResult?.fidelity);

  /// [route] walked from a solved origin, as the corners of the polyline; null when no
  /// candidate attach point closes it.
  final List<ViPoint>? routePoints;

  final WireRouteFidelity? routePointsFidelity;

  /// For a walked route whose tail already lies inside the far box: the one-pixel direction the
  /// tail should keep moving in.
  final ViStep? routeClosingStep;

  /// For a route solved from its tail: the direction the head end may slide along.
  final ViStep? routeHeadSlack;

  /// The signal's type word.
  final ViSignalType? signalType;

  ViTypeKind? get typeKind => signalType?.typeKind;

  ViTypeKind? get elementTypeKind => signalType?.elementKind;
}

/// A diagram position in pixels.
typedef ViPoint = ({int x, int y});

/// A unit direction or offset in pixels.
typedef ViStep = ({int dx, int dy});

/// The direction of a route's first segment, as the route table codes it; the codes are bits
/// so a branch route's first mode can name several.
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

  /// The direction with [code], or null when the code is not exactly one direction.
  static WireRouteDirection? fromCode(int code) => _byCode[code];
}

/// A two-endpoint wire's route table: `[pointCount][direction][pointCount − 2 joint signs]`
/// `[pointCount − 2 segment lengths]`, a sign byte `0` turning positive and `1` negative, a
/// length byte `ff` escaping to a `u16`; a table of one byte is a single point.
class ViWireRoute {
  ViWireRoute({
    required this.pointCount,
    this.direction = WireRouteDirection.right,
    required this.segmentLengths,
    required this.jointSigns,
  });

  final int pointCount;

  /// The first segment's direction; null for a single-point route.
  final WireRouteDirection? direction;

  /// Each segment's length in pixels; segments alternate horizontal and vertical.
  final List<int> segmentLengths;

  /// Per segment after the first, `1` or `-1`: the sign of its axis step.
  final List<int> jointSigns;
}

List<int>? _decodeLengthTail(Uint8List table, int start) {
  var i = start;
  final lengths = <int>[];
  while (i < table.length) {
    var value = table[i++];
    if (value == 0xff) {
      if (i + 1 >= table.length) return null;
      value = ByteData.sublistView(table).getUint16(i);
      i += 2;
    }
    lengths.add(value);
  }
  return lengths;
}

// TODO: a residue of two-endpoint tables opening with the up code carries two trailing bytes this grammar does not explain.
/// The route of a two-endpoint wire, or null when [table] does not follow the [ViWireRoute]
/// grammar.
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

/// A branch route mode that forks the wire: which directions leave the junction, in the order
/// the walk takes them; the direction the wire arrived from is replaced by [WireRouteDirection.left].
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

  /// The junction with [code], or null for a code that is not one.
  static WireRouteJunction? fromCode(int code) => _byCode[code];
}

/// A branching wire's route table: `[pointCount][00][pointCount − 1 modes][pointCount − 1`
/// `segment lengths]`. The first mode is a set of [WireRouteDirection] bits; a later mode of
/// `0` or `1` turns positive or negative across the previous axis, [popCode] returns to the
/// last junction with directions left to walk, and any other mode is a [WireRouteJunction].
class ViWireBranchRoute {
  ViWireBranchRoute._({required this.pointCount, required this.modes, required this.segmentLengths});

  /// The mode that ends a branch and resumes at the last open junction.
  static const int popCode = 0x03;

  final int pointCount;

  final Uint8List modes;

  /// One length in pixels per mode.
  final List<int> segmentLengths;
}

/// The route of a branching wire, or null when [table] does not follow the
/// [ViWireBranchRoute] grammar or its junctions and pops do not balance.
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

/// A branching route placed on the diagram: one polyline per branch, each starting at the
/// origin or a junction and ending at a leaf.
class ViWireRouteTree {
  ViWireRouteTree({required this.polylines, required this.junctions});

  final List<List<ViPoint>> polylines;

  /// Where branches fork.
  final List<ViPoint> junctions;

  /// The end of every branch; a wire with `n` endpoints has `n − 1` leaves.
  late final List<ViPoint> leaves = [for (final polyline in polylines) polyline.last];
}

/// Places [route] with its first point at [start].
ViWireRouteTree walkWireBranchRoute(ViWireBranchRoute route, ViPoint start) {
  final modes = route.modes;
  final lengths = route.segmentLengths;
  final polylines = <List<ViPoint>>[];
  final junctionPoints = <ViPoint>[];
  final stack = <(ViPoint, List<WireRouteDirection>)>[];
  var run = <ViPoint>[start];
  var pos = start;
  late WireRouteDirection prev;
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
      direction = prev.isHorizontal
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
      final blocked = _reverse(prev);
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

/// The corners of [route] walked from [origin], with the axis and sign of the segment that
/// would follow the last corner; null for a single-point route.
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

/// Places [route] with the endpoint at [anchoredIndex] fixed at [anchor] and the other end
/// closing on [farBox]: walked forward from the head, or walked backward from the tail when
/// [anchoredIndex] is 1. Null when the closing segment misses the box.
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
