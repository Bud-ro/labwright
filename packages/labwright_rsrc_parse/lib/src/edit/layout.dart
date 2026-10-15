import '../diagram/wire_route.dart';
import '../heap/heap.dart';
import 'block_diagram.dart';
import 'records.dart';

/// Space around or inside a box, in pixels.
class BdInsets {
  const BdInsets({this.top = 0, this.left = 0, this.bottom = 0, this.right = 0});

  const BdInsets.all(int each) : this(top: each, left: each, bottom: each, right: each);

  const BdInsets.symmetric({int vertical = 0, int horizontal = 0})
    : this(top: vertical, left: horizontal, bottom: vertical, right: horizontal);

  final int top;

  final int left;

  final int bottom;

  final int right;

  int get horizontal => left + right;

  int get vertical => top + bottom;

  @override
  String toString() => 'BdInsets($top, $left, $bottom, $right)';
}

/// A width and a height, in pixels.
class BdSize {
  const BdSize(this.width, this.height);

  const BdSize.square(int side) : this(side, side);

  static const zero = BdSize(0, 0);

  final int width;

  final int height;

  @override
  String toString() => '$width×$height';
}

/// Where the diagram's objects go, decided by their wires: an object sits one column right of
/// every object that feeds it and on the row that keeps its first wire straight; a structure
/// wraps its body in its padding; a tunnel sits on the row of the object it serves inside.
///
/// Objects placed with bounds keep them; the rest are laid out when the diagram is written,
/// and every wire the editor made is routed afterwards.
class BdLayout {
  BdLayout(this.root);

  /// The diagram's root frame.
  final BdFrame root;

  /// Lays out every frame from the innermost out, then routes the wires.
  void run() {
    _layoutFrame(root);
    _route(root);
  }

  static bool _isLaidOut(BdPlaced item) =>
      item is BdNode || item is BdConstant || item is BdPanelTerminal || item is BdText;

  /// Lays the frame's items out and returns the extent of their outer boxes.
  BdSize _layoutFrame(BdFrame frame) {
    final items = [
      for (final item in frame.placed)
        if (_isLaidOut(item)) item,
    ];
    for (final item in items) {
      if (item is BdStructure) _sizeStructure(item);
    }
    final auto = items.where((item) => item.autoPlaced).toList();
    if (auto.isEmpty) return _extent(items);
    var contentTop = frame.padding.top;
    for (final item in auto) {
      if (item is! BdText) continue;
      _moveTo(item, frame.padding.left, contentTop);
      contentTop += _outer(item).height + frame.rowGap;
    }
    final column = _columns(frame, items);
    final byColumn = <int, List<BdPlaced>>{};
    for (final item in auto) {
      if (item is BdText) continue;
      byColumn.putIfAbsent(column[item]!, () => []).add(item);
    }
    final columns = byColumn.keys.toList()..sort();
    var x = frame.padding.left;
    final rowOf = <BdPlaced, int>{};
    for (final c in columns) {
      final members = byColumn[c]!;
      final desired = <BdPlaced, int>{};
      for (final item in members) {
        desired[item] = _desiredTop(frame, item, rowOf) ?? contentTop;
      }
      members.sort((a, b) {
        final byRow = desired[a]!.compareTo(desired[b]!);
        return byRow != 0 ? byRow : frame.placed.indexOf(a).compareTo(frame.placed.indexOf(b));
      });
      var bottom = contentTop;
      var width = 0;
      for (final item in members) {
        final outer = _outer(item);
        final top = desired[item]!.clamp(bottom, 1 << 20);
        _moveTo(item, x, top);
        rowOf[item] = top;
        bottom = top + outer.height + frame.rowGap;
        if (outer.width > width) width = outer.width;
      }
      x += width + frame.gap;
    }
    final owner = frame.owner;
    if (owner != null) _placeBorderTerminals(owner, frame);
    return _extent(items);
  }

  /// The column of each item: one past its farthest source, a control at the left, a
  /// constant just before what it feeds.
  Map<BdPlaced, int> _columns(BdFrame frame, List<BdPlaced> allItems) {
    var items = allItems;
    final sources = <BdPlaced, Set<BdPlaced>>{for (final item in items) item: {}};
    final sinks = <BdPlaced, Set<BdPlaced>>{for (final item in items) item: {}};
    items = items.where((item) => item is! BdText).toList();
    for (final wire in frame.wires) {
      final source = wire.source;
      if (source == null) continue;
      final from = _itemOf(frame, source);
      for (final end in wire.sinks) {
        final to = _itemOf(frame, end);
        if (from == null || to == null || identical(from, to)) continue;
        sources[to]!.add(from);
        sinks[from]!.add(to);
      }
    }
    final column = <BdPlaced, int>{};
    int columnOf(BdPlaced item, Set<BdPlaced> walking) {
      final known = column[item];
      if (known != null) return known;
      if (!walking.add(item)) return 0;
      var at = 0;
      for (final source in sources[item]!) {
        if (source is BdConstant) continue;
        final c = columnOf(source, walking) + 1;
        if (c > at) at = c;
      }
      walking.remove(item);
      return column[item] = at;
    }

    for (final item in items) {
      if (item is! BdConstant) columnOf(item, {});
    }
    var feedsFirstColumn = false;
    for (final item in items) {
      if (item is BdConstant && sinks[item]!.any((sink) => column[sink] == 0)) feedsFirstColumn = true;
    }
    if (feedsFirstColumn) {
      for (final item in items) {
        if (item is! BdConstant) column[item] = column[item]! + 1;
      }
    }
    for (final item in items) {
      if (item is! BdConstant) continue;
      int? before;
      for (final sink in sinks[item]!) {
        final c = column[sink] ?? 0;
        if (before == null || c < before) before = c;
      }
      column[item] = before == null ? 0 : before - 1;
    }
    return column;
  }

  /// The row the item wants: the one that keeps its first wire from an already placed
  /// source straight, else the row its own sources sit on.
  int? _desiredTop(BdFrame frame, BdPlaced item, Map<BdPlaced, int> rowOf) {
    for (final wire in frame.wires) {
      final source = wire.source;
      if (source == null) continue;
      final from = _itemOf(frame, source);
      for (final end in wire.sinks) {
        if (!identical(_itemOf(frame, end), item) || from == null || !rowOf.containsKey(from)) continue;
        final sourceRow = source.attachPoint.y;
        final sinkOffset = end.attachPoint.y - (item.bounds?.top ?? 0);
        return sourceRow - sinkOffset - _labelAbove(item);
      }
    }
    return null;
  }

  /// The item an endpoint belongs to within [frame]; null for an endpoint of the frame's own
  /// structure seen from inside.
  BdPlaced? _itemOf(BdFrame frame, BdEndpoint end) {
    if (end is BdTerminal && end.owner != null) return end.owner;
    for (final item in frame.placed) {
      if (item.oid == end.oid) return item;
      if (item is BdStructure) {
        for (final t in item.borderTerminals) {
          if (t.holder != null && t.outer.oid == end.oid) return item;
        }
      }
    }
    return null;
  }

  /// The item's box with its label and margin: width, height, and how far its bounds sit
  /// in from the outer box's top left.
  ({int width, int height, int dx, int dy}) _outer(BdPlaced item) {
    final b = item.bounds ?? kZeroRect;
    final w = b.right - b.left, h = b.bottom - b.top;
    final m = item.margin;
    final label = item.labelSize;
    switch (item) {
      case BdPanelTerminal():
        return item.isIndicator
            ? (width: w + label.width + m.horizontal, height: h + m.vertical, dx: m.left, dy: m.top)
            : (width: w + label.width + m.horizontal, height: h + m.vertical, dx: m.left + label.width, dy: m.top);
      case BdConstant():
        return (
          width: (w > label.width ? w : label.width) + m.horizontal,
          height: h + label.height + m.vertical,
          dx: m.left,
          dy: m.top + label.height,
        );
      case BdNode():
        return (
          width: (w > label.width ? w : label.width) + m.horizontal,
          height: h + label.height + m.vertical,
          dx: m.left,
          dy: m.top + label.height,
        );
      case _:
        return (width: w + m.horizontal, height: h + m.vertical, dx: m.left, dy: m.top);
    }
  }

  int _labelAbove(BdPlaced item) => item is BdConstant || item is BdNode ? item.labelSize.height : 0;

  void _moveTo(BdPlaced item, int outerLeft, int outerTop) {
    final b = item.bounds ?? kZeroRect;
    final outer = _outer(item);
    final left = outerLeft + outer.dx, top = outerTop + outer.dy;
    item.bounds = HeapRect(
      top: top,
      left: left,
      bottom: top + (b.bottom - b.top),
      right: left + (b.right - b.left),
    );
  }

  BdSize _extent(List<BdPlaced> items) {
    var right = 0, bottom = 0;
    for (final item in items) {
      final b = item.bounds;
      if (b == null) continue;
      final outer = _outer(item);
      final r = b.left - outer.dx + outer.width, d = b.top - outer.dy + outer.height;
      if (r > right) right = r;
      if (d > bottom) bottom = d;
    }
    return BdSize(right, bottom);
  }

  /// Lays out the structure's frames and sizes the structure to the largest, plus its padding;
  /// a sequence sizes each of its frames so.
  void _sizeStructure(BdStructure structure) {
    if (!structure.autoPlaced) return;
    var width = structure.minSize.width, height = structure.minSize.height;
    for (final frame in structure.frames) {
      final extent = _layoutFrame(frame);
      final w = extent.width + structure.padding.right, h = extent.height + structure.padding.bottom;
      if (w > width) width = w;
      if (h > height) height = h;
    }
    if (structure is BdSequence) {
      structure.sizeFrames(BdSize(width, height));
    } else {
      structure.bounds = HeapRect(top: 0, left: 0, bottom: height, right: width);
    }
  }

  /// Puts each tunnel and shift register on the row of what it serves inside [frame].
  void _placeBorderTerminals(BdStructure structure, BdFrame frame) {
    final rows = <BdStructureTerminal, int>{};
    for (final wire in frame.wires) {
      final source = wire.source;
      if (source == null) continue;
      final ends = [source, ...wire.sinks];
      for (final end in ends) {
        for (final t in structure.borderTerminals) {
          if (t.inners.any((p) => p.oid == end.oid) && !rows.containsKey(t)) {
            final other = ends.firstWhere((e) => e.oid != end.oid, orElse: () => end);
            if (other.oid != end.oid) rows[t] = other.attachPoint.y;
          }
        }
      }
    }
    for (final MapEntry(key: terminal, value: row) in rows.entries) {
      terminal.row = row;
    }
    for (final sr in structure.borderTerminals) {
      if (sr.kind == BdBorderKind.leftShiftRegister || sr.kind == BdBorderKind.rightShiftRegister) {
        final partner = sr.partner;
        if (partner != null && rows.containsKey(sr) && !rows.containsKey(partner)) partner.row = rows[sr]!;
      }
    }
  }

  /// Routes every wire the editor made: straight when its ends share a row, else turning in
  /// the gap before the sink.
  void _route(BdFrame frame) {
    for (final item in frame.placed) {
      if (item is BdStructure) {
        for (final inner in item.frames) {
          _route(inner);
        }
      }
    }
    for (final wire in frame.wires) {
      final from = wire.source;
      if (from == null) continue;
      final sinks = wire.sinks;
      var nearest = 1 << 20;
      for (final sink in sinks) {
        final item = _itemOf(frame, sink);
        final left = item == null ? sink.attachPoint.x : item.bounds!.left - _outer(item).dx;
        if (left < nearest) nearest = left;
      }
      final fromItem = _itemOf(frame, from);
      final fromRight = fromItem == null
          ? from.attachPoint.x
          : fromItem.bounds!.left - _outer(fromItem).dx + _outer(fromItem).width - fromItem.margin.right;
      final bendX = nearest > fromRight ? (fromRight + nearest) ~/ 2 : from.attachPoint.x + frame.gap ~/ 2;
      wire.route(bdRouteFanOut(from.attachPoint, [for (final s in sinks) s.attachPoint], bendX: bendX));
      final text = wire.labelText;
      if (text != null) {
        final box = bdTextBox(text);
        final at = from.attachPoint;
        wire.placeLabel(
          HeapRect(top: at.y - box.bottom - 2, left: at.x + 4, bottom: at.y - 2, right: at.x + 4 + box.right),
        );
      }
    }
  }
}

/// The compressed table of a wire from [from] to each of [sinks]: a straight run or one
/// turn to a single sink; to several, a run right to a junction in column [bendX] (halfway
/// to the nearest sink unless given) that forks up, down or on, each side forking again at
/// every sink's row but the last, where it turns to the sink.
WireTable bdRouteFanOut(ViPoint from, List<ViPoint> sinks, {int? bendX}) {
  if (sinks.length == 1) return _bdRouteBetween(from, sinks.single, bendX);
  var nearest = sinks.first.x;
  for (final sink in sinks) {
    if (sink.x < nearest) nearest = sink.x;
  }
  final junctionX = bendX ?? from.x + ((nearest - from.x) ~/ 2).clamp(4, 1 << 15);
  final up = [
    for (final sink in sinks)
      if (sink.y < from.y) sink,
  ]..sort((a, b) => b.y.compareTo(a.y));
  final down = [
    for (final sink in sinks)
      if (sink.y > from.y) sink,
  ]..sort((a, b) => a.y.compareTo(b.y));
  final on = [
    for (final sink in sinks)
      if (sink.y == from.y) sink,
  ];
  if (on.length > 1) {
    final points = [from];
    for (final sink in sinks) {
      points.addAll([(x: sink.x, y: points.last.y), sink]);
    }
    return _bdRoutePolyline(points);
  }
  final modes = <int>[WireRouteDirection.right.code];
  final lengths = <int>[junctionX - from.x];

  void side(List<ViPoint> sinks, int i, WireRouteJunction fork) {
    final sink = sinks[i];
    if (i == sinks.length - 1) {
      modes.add(sink.x >= junctionX ? 0 : 1);
      lengths.add((sink.x - junctionX).abs());
      return;
    }
    modes.add(fork.code);
    lengths.add((sinks[i + 1].y - sink.y).abs());
    side(sinks, i + 1, fork);
    modes.add(ViWireBranchRoute.popCode);
    lengths.add((sink.x - junctionX).abs());
  }

  if (on.isEmpty && (up.isEmpty || down.isEmpty)) {
    final only = up.isNotEmpty ? up : down;
    modes.add(up.isNotEmpty ? 1 : 0);
    lengths.add((only.first.y - from.y).abs());
    side(only, 0, up.isNotEmpty ? WireRouteJunction.upRight : WireRouteJunction.downRight);
    return WireTable(modes.length + 1, header: const [], modes: modes, lengths: lengths);
  }
  final first = switch ((up.isNotEmpty, down.isNotEmpty, on.isNotEmpty)) {
    (true, true, true) => WireRouteJunction.cross,
    (true, true, false) => WireRouteJunction.upDown,
    (true, false, _) => WireRouteJunction.upRight,
    _ => WireRouteJunction.downRight,
  };
  modes.add(first.code);
  for (final (k, direction) in first.outgoing.indexed) {
    if (k > 0) modes.add(ViWireBranchRoute.popCode);
    switch (direction) {
      case WireRouteDirection.up:
        lengths.add(from.y - up.first.y);
        side(up, 0, WireRouteJunction.upRight);
      case WireRouteDirection.down:
        lengths.add(down.first.y - from.y);
        side(down, 0, WireRouteJunction.downRight);
      case _:
        lengths.add(on.single.x - junctionX);
    }
  }
  return WireTable(modes.length + 1, header: const [], modes: modes, lengths: lengths);
}

WireTable _bdRouteBetween(ViPoint from, ViPoint to, int? bendX) {
  final dx = to.x - from.x, dy = to.y - from.y;
  if (dy == 0) return WireTable(2, modes: [(dx >= 0 ? WireRouteDirection.right : WireRouteDirection.left).code]);
  if (dx == 0) return WireTable(2, modes: [(dy >= 0 ? WireRouteDirection.down : WireRouteDirection.up).code]);
  if (bendX == from.x) return _bdRoutePolyline([from, (x: from.x, y: to.y), to]);
  if (bendX != null && bendX != to.x) return _bdRoutePolyline([from, (x: bendX, y: from.y), (x: bendX, y: to.y), to]);
  return _bdRoutePolyline([from, (x: to.x, y: from.y), to]);
}

/// The plain table of an axis-aligned polyline: the first direction, a turn sign per later
/// segment, and every length but the last.
WireTable _bdRoutePolyline(List<ViPoint> points) {
  final modes = <int>[], lengths = <int>[];
  var horizontal = true;
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    final dx = b.x - a.x, dy = b.y - a.y;
    if (i == 1) {
      horizontal = dy == 0;
      modes.add(
        (horizontal
                ? (dx >= 0 ? WireRouteDirection.right : WireRouteDirection.left)
                : (dy >= 0 ? WireRouteDirection.down : WireRouteDirection.up))
            .code,
      );
    } else {
      horizontal = !horizontal;
      modes.add((horizontal ? dx : dy) >= 0 ? 0 : 1);
    }
    if (i < points.length - 1) lengths.add((horizontal ? dx : dy).abs());
  }
  return WireTable(points.length, modes: modes, lengths: lengths);
}
