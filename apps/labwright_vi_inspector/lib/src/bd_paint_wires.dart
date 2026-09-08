part of 'diagram_view.dart';

bool _polylineUnderNodes(List<Offset> points, List<Rect> cover) {
  for (var segmentIndex = 1; segmentIndex < points.length; segmentIndex++) {
    final start = points[segmentIndex - 1], end = points[segmentIndex];
    final horizontal = start.dy == end.dy;
    final runLo = horizontal
        ? math.min(start.dx, end.dx)
        : math.min(start.dy, end.dy);
    final runHi = horizontal
        ? math.max(start.dx, end.dx)
        : math.max(start.dy, end.dy);
    var at = runLo;
    var progressed = true;
    while (at <= runHi && progressed) {
      progressed = false;
      for (final box in cover) {
        final crossOk = horizontal
            ? (start.dy >= box.top && start.dy < box.bottom)
            : (start.dx >= box.left && start.dx < box.right);
        if (!crossOk) continue;
        final (boxLo, boxHi) = horizontal
            ? (box.left, box.right)
            : (box.top, box.bottom);
        if (boxLo <= at + 1 && boxHi > at) {
          at = boxHi;
          progressed = true;
        }
      }
    }
    if (at <= runHi) return false;
  }
  return points.isNotEmpty;
}

extension _WirePass on BdDiagramPainter {
  void _paintWireObjects(Canvas canvas, List<ViHeapObject> wires) {
    final wirePaint = Paint()
      ..color = _kindColor(ViObjectKind.wire)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    for (final object in wires) {
      final rect = _rectOf(object);
      if (rect.width == 0 && rect.height == 0) continue;
      canvas.drawLine(rect.topLeft, rect.bottomRight, wirePaint);
    }
  }

  void _drawWires(
    Canvas canvas, {
    List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >?
    tunnelSquares,
  }) {
    if (wires.isEmpty) return;
    final anchors = _collectWireAnchors();
    final nets = _resolveWireNets(anchors);
    final drawn = <_BdWireSeg>[];
    for (final wire in wires) {
      _drawOneWire(
        canvas,
        wire,
        anchors: anchors,
        nets: nets,
        drawn: drawn,
        tunnelSquares: tunnelSquares,
      );
    }
  }

  _BdWireAnchors _collectWireAnchors() {
    final typedTerminalColors = <int, Color>{};
    final sourceOutputColors = <int, Color>{};
    final iconNodeRects = <Rect>{};
    final iconInkRects = <Rect, Rect>{};
    final iconNodeObjects = <Rect, ViHeapObject>{};
    final nodeCoverRects = <Rect>[];
    for (final object in objects) {
      final bounds = object.absBounds;
      if (bounds == null) continue;
      if (object.category == ViObjectKind.node &&
          bounds.width > 0 &&
          bounds.height > 0) {
        nodeCoverRects.add(_toCanvas(bounds));
      }
      final packed = _packRect(
        bounds.top,
        bounds.left,
        bounds.bottom,
        bounds.right,
      );
      if (object.category == ViObjectKind.terminal &&
          object.typeKind != ViTypeKind.unknown) {
        typedTerminalColors[packed] = bdTerminalTypeColor(object);
      }
      final iconKey = loadedPrimIconIdOf(object);
      if (iconKey != null) {
        final boxRect = _toCanvas(bounds);
        iconNodeRects.add(boxRect);
        iconNodeObjects[boxRect] = object;
        final art = primIcons[iconKey]?.base;
        final ink = primIconInkBounds(iconKey);
        if (art != null && ink != null) {
          final stamp = primIconStampRect(
            boxRect,
            art.width,
            art.height,
            key: iconKey,
          );
          iconInkRects[boxRect] = ink.shift(stamp.topLeft);
        }
      }
      final output = object.primResId == null
          ? null
          : PrimOp.fromId(object.primResId!)?.output;
      if (output != null) {
        sourceOutputColors[packed] = labviewTypeColor(output);
      }
    }
    final furnitureRects = <Rect>[
      for (final bounds in scene.furnitureBounds) _toCanvas(bounds),
    ];
    return (
      typedTerminalColors: typedTerminalColors,
      sourceOutputColors: sourceOutputColors,
      iconNodeRects: iconNodeRects,
      iconInkRects: iconInkRects,
      iconNodeObjects: iconNodeObjects,
      nodeCoverRects: nodeCoverRects,
      furnitureRects: furnitureRects,
    );
  }

  Map<int, ({Color? color, bool error})> _resolveWireNets(
    _BdWireAnchors anchors,
  ) {
    final typedTerminalColors = anchors.typedTerminalColors;
    final sourceOutputColors = anchors.sourceOutputColors;
    const unresolvedGrey = Color(0xFF8A8A8A);
    final netParent = <int, int>{
      for (final wire in wires) wire.signalOid: wire.signalOid,
    };
    int netFind(int signalOid) {
      var root = signalOid;
      while (netParent[root] != root) {
        root = netParent[root]!;
      }
      var cursor = signalOid;
      while (netParent[cursor] != root) {
        final next = netParent[cursor]!;
        netParent[cursor] = root;
        cursor = next;
      }
      return root;
    }

    void netUnion(int left, int right) =>
        netParent[netFind(left)] = netFind(right);
    final pointOwner = <int, int>{};
    List<ViPoint> netPointsOf(ViWire wire) => [
      for (final run in [
        if (wire.routePoints case final points? when points.isNotEmpty) points,
        ...?wire.routeTree?.polylines,
      ]) ...[run.first, run.last],
      ...?wire.routeTree?.junctions,
    ];
    for (final wire in wires) {
      final keys = [
        for (final point in netPointsOf(wire))
          ((point.x + 0x8000) << 17) | (point.y + 0x8000),
        for (final attach in wire.endpointAttachRects)
          if (attach != null && attach.width > 0 && attach.height > 0)
            _packRect(attach.top, attach.left, attach.bottom, attach.right),
      ];
      for (final key in keys) {
        final owner = pointOwner[key];
        if (owner == null) {
          pointOwner[key] = wire.signalOid;
        } else {
          netUnion(wire.signalOid, owner);
        }
      }
    }
    final netBest = <int, (int, Color)>{};
    final netError = <int, bool>{};
    for (final wire in wires) {
      final root = netFind(wire.signalOid);
      void consider(int tier, Color? color) {
        if (color == null || color == unresolvedGrey) return;
        final best = netBest[root];
        if (best == null || tier < best.$1) netBest[root] = (tier, color);
      }

      for (final anchor in wire.endpointAnchors) {
        if (anchor == null) continue;
        consider(
          0,
          typedTerminalColors[_packRect(
            anchor.top,
            anchor.left,
            anchor.bottom,
            anchor.right,
          )],
        );
      }
      for (final oid in wire.endpointOids) {
        final endpoint = scene.diagram.byId[oid];
        if (endpoint == null) continue;
        if (_isErrorClusterMembers(endpoint.resolvedMembers)) {
          netError[root] = true;
        }
        if (endpoint.resolvedMembers.isNotEmpty ||
            endpoint.resolvedElementMembers.isNotEmpty ||
            endpoint.typeKind != ViTypeKind.unknown) {
          consider(1, bdTerminalTypeColor(endpoint));
        }
      }
      final source = wire.endpointAnchors.firstWhere(
        (anchor) => anchor != null,
        orElse: () => null,
      );
      if (source != null) {
        consider(
          2,
          sourceOutputColors[_packRect(
            source.top,
            source.left,
            source.bottom,
            source.right,
          )],
        );
      }
      final wordKind = wire.elementTypeKind;
      if (wordKind != null && wordKind != ViTypeKind.unknown) {
        consider(
          3,
          wordKind == ViTypeKind.refnum
              ? const Color(0xFF006666)
              : labviewTypeColor(wordKind),
        );
      }
    }
    final resolved = <int, ({Color? color, bool error})>{};
    for (final wire in wires) {
      final root = netFind(wire.signalOid);
      resolved[wire.signalOid] = (
        color: netBest[root]?.$2,
        error: netError[root] ?? false,
      );
    }
    return resolved;
  }

  void _drawOneWire(
    Canvas canvas,
    ViWire wire, {
    required _BdWireAnchors anchors,
    required Map<int, ({Color? color, bool error})> nets,
    required List<_BdWireSeg> drawn,
    required List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >?
    tunnelSquares,
  }) {
    final tunnels = _wireTunnelChrome(wire);
    final net = nets[wire.signalOid]!;
    var color = net.color ?? kBdWireColor;
    var errorBraid = false;
    if (wire.signalType?.renderStyle == ViWireRenderStyle.braid) {
      errorBraid =
          net.error || net.color == null || color == const Color(0xFF666600);
      if (errorBraid) color = const Color(0xFF666600);
    }
    final wireDisabled = disabledOids.contains(wire.signalOid);
    if (wireDisabled) color = bdDimDisabled(color);
    tunnelSquares?.addAll([
      for (final (tunnelRect, info) in tunnels)
        (
          tunnelRect,
          info,
          info.disabled && !wireDisabled ? bdDimDisabled(color) : color,
        ),
    ]);
    final routePoints = wire.routePoints;
    final routeTree = wire.routeTree;
    final legs = <List<Offset>>[];
    final junctions = <Offset>[];
    var stubEligible = routeTree == null && routePoints == null;
    if (routeTree != null) {
      for (final run in routeTree.polylines) {
        legs.add([
          for (final point in run)
            Offset(point.x - origin.dx, point.y - origin.dy),
        ]);
      }
      for (final junction in routeTree.junctions) {
        junctions.add(Offset(junction.x - origin.dx, junction.y - origin.dy));
      }
    } else if (routePoints != null) {
      final points = _resolvedRoutePolyline(wire, routePoints, anchors);
      if (points.length >= 2) {
        if (!_polylineUnderNodes(points, anchors.nodeCoverRects)) {
          legs.add(points);
        } else {
          stubEligible = true;
        }
      }
    } else if (wire.branchRoute != null && wire.endpointOids.length >= 3) {
      final headTerminal = bdPrimTerminalOf(
        scene.diagram,
        wire.endpointOids[0],
      );
      if (headTerminal?.x != null && headTerminal?.y != null) {
        final tree = walkWireBranchRoute(wire.branchRoute!, (
          x: headTerminal!.x!,
          y: headTerminal.y!,
        ));
        final leaves = tree.leaves;
        var closed = leaves.length == wire.endpointOids.length - 1;
        if (closed) {
          final remaining = <ViPoint, int>{};
          for (final leaf in leaves) {
            remaining.update(leaf, (count) => count + 1, ifAbsent: () => 1);
          }
          for (
            var endpointIndex = 1;
            endpointIndex < wire.endpointOids.length;
            endpointIndex++
          ) {
            final oid = wire.endpointOids[endpointIndex];
            final term = bdPrimTerminalOf(scene.diagram, oid);
            ViPoint? match;
            for (final candidate in [
              if (term?.x != null && term?.y != null) (x: term!.x!, y: term.y!),
              ...?scene.diagram.dcoChildTerminalAttach(oid)?.candidates,
            ]) {
              if (remaining.containsKey(candidate)) {
                match = candidate;
                break;
              }
            }
            if (match == null) {
              closed = false;
              break;
            }
            final count = remaining[match]!;
            if (count == 1) {
              remaining.remove(match);
            } else {
              remaining[match] = count - 1;
            }
          }
        }
        if (closed) {
          for (final run in tree.polylines) {
            legs.add([
              for (final point in run)
                Offset(point.x - origin.dx, point.y - origin.dy),
            ]);
          }
          for (final junction in tree.junctions) {
            junctions.add(
              Offset(junction.x - origin.dx, junction.y - origin.dy),
            );
          }
        }
      }
    }
    if (stubEligible) {
      if (legs.isEmpty) _straightStubLeg(wire, legs);
      if (legs.isEmpty) _threePointStubLeg(wire, legs);
      if (legs.isEmpty) _walkedRouteLeg(wire, legs);
      if (legs.isEmpty) _coveredAttachWalkLeg(wire, legs);
      if (legs.isEmpty) _containerFaceLeg(wire, legs);
    }
    final style = _wireStrokeStyle(wire);
    final fill = _solidNoAa(color);
    _strokeWireLegs(
      canvas,
      fill,
      style,
      legs,
      junctions,
      drawn,
      errorBraid: errorBraid,
    );
    for (final junction in junctions) {
      _drawWireJunctionDot(
        canvas,
        junction,
        fill,
        bdWireStrokeBand(style),
        style: style,
        errorBraid: errorBraid,
      );
    }
  }

  List<(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>
  _wireTunnelChrome(ViWire wire) {
    final tunnels =
        <(Rect, ({int kind, bool hollow, bool centreDot, bool disabled}))>[];
    for (
      var endpointIndex = 0;
      endpointIndex < wire.endpointAnchors.length;
      endpointIndex++
    ) {
      final anchor = wire.endpointAnchors[endpointIndex];
      if (anchor == null) continue;
      if (anchor.width <= 0 && anchor.height <= 0) continue;
      final attach = endpointIndex < wire.endpointAttachRects.length
          ? wire.endpointAttachRects[endpointIndex]
          : null;
      if (attach == null) continue;
      final attachRect = _toCanvas(attach);
      final info = borderTerminalKinds[attach];
      if (info != null) tunnels.add((attachRect, info));
    }
    return tunnels;
  }

  List<Offset> _resolvedRoutePolyline(
    ViWire wire,
    List<ViPoint> routePoints,
    _BdWireAnchors anchors,
  ) {
    final points = [
      for (final point in routePoints)
        Offset(point.x - origin.dx, point.y - origin.dy),
    ];
    if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
      final slack = wire.routeHeadSlack;
      if (slack != null) {
        _slideSlackHead(wire, points, slack);
      } else {
        _reanchorPolyline(wire, points, anchors);
      }
      final sinkBox = points.isEmpty
          ? null
          : _iconBoxOfEndpoint(
              wire,
              wire.endpointAnchors.length - 1,
              anchors.iconNodeRects,
            );
      if (sinkBox != null) {
        _extendIntoSinkIcon(wire, points, sinkBox, anchors);
      }
    }
    if (points.length >= 2 && wire.endpointAnchors.length >= 2) {
      _trimEndToFurniture(wire, points, anchors, head: true);
      _trimEndToFurniture(wire, points, anchors, head: false);
    }
    return points;
  }

  Rect? _iconBoxOfEndpoint(
    ViWire wire,
    int endpointIndex,
    Set<Rect> iconNodeRects,
  ) {
    final anchor = wire.endpointAnchors[endpointIndex];
    if (anchor == null) return null;
    final box = Rect.fromLTRB(
      anchor.left - origin.dx,
      anchor.top - origin.dy,
      anchor.right - origin.dx,
      anchor.bottom - origin.dy,
    );
    return iconNodeRects.contains(box) ? box : null;
  }

  void _slideSlackHead(ViWire wire, List<Offset> points, ViStep slack) {
    final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[0]);
    final terminalX = terminal?.x, terminalY = terminal?.y;
    final head = points.first;
    final slide = slack.dx != 0
        ? (terminalX == null ? null : terminalX - origin.dx - head.dx)
        : (terminalY == null ? null : terminalY - origin.dy - head.dy);
    final resolved =
        terminalX != null &&
        terminalY != null &&
        slide != null &&
        slide * (slack.dx + slack.dy) >= 0 &&
        (slack.dx != 0
            ? (head.dy + origin.dy).round() == terminalY
            : (head.dx + origin.dx).round() == terminalX);
    if (!resolved) {
      points.clear();
    } else {
      final delta = slack.dx != 0 ? Offset(slide, 0) : Offset(0, slide);
      for (var index = 0; index < points.length - 1; index++) {
        points[index] = points[index] + delta;
      }
    }
  }

  void _reanchorPolyline(
    ViWire wire,
    List<Offset> points,
    _BdWireAnchors anchors,
  ) {
    Offset? reanchor;
    var reanchorConflict = false;
    if (wire.endpointOids.length == 2) {
      for (final (endpointIndex, point) in [
        (0, points.first),
        (1, points.last),
      ]) {
        final oid = wire.endpointOids[endpointIndex];
        if (scene.diagram.wireAttachPoint(oid) != null) continue;
        final abs = (
          x: (point.dx + origin.dx).round(),
          y: (point.dy + origin.dy).round(),
        );
        final candidates = scene.diagram
            .dcoChildTerminalAttach(oid)
            ?.candidates;
        if (candidates == null || !candidates.contains(abs)) continue;
        final term = bdPrimTerminalOf(scene.diagram, oid);
        if (term?.x == null || term?.y == null) continue;
        final delta = Offset(
          (term!.x! - abs.x).toDouble(),
          (term.y! - abs.y).toDouble(),
        );
        if (delta == Offset.zero) continue;
        if (reanchor == null) {
          reanchor = delta;
        } else if (reanchor != delta) {
          reanchorConflict = true;
        }
      }
    }
    if (reanchorConflict) {
      points.clear();
    } else if (reanchor != null) {
      for (var index = 0; index < points.length; index++) {
        points[index] = points[index] + reanchor;
      }
    }
    final sourceBox = _iconBoxOfEndpoint(wire, 0, anchors.iconNodeRects);
    if (points.length >= 2 && sourceBox != null) {
      final inkCentre = (anchors.iconInkRects[sourceBox] ?? sourceBox).center;
      final head = points.first, next = points[1];
      points[0] = head.dy == next.dy
          ? Offset(inkCentre.dx, head.dy)
          : Offset(head.dx, inkCentre.dy);
    }
  }

  void _extendIntoSinkIcon(
    ViWire wire,
    List<Offset> points,
    Rect sinkBox,
    _BdWireAnchors anchors,
  ) {
    final ink = anchors.iconInkRects[sinkBox] ?? sinkBox;
    final closing = wire.routeClosingStep;
    if (closing != null) {
      final last = points.last;
      final farObj = anchors.iconNodeObjects[sinkBox];
      final Offset target;
      if (closing.dx != 0) {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: true,
                cross: (last.dy + origin.dy).round(),
                sign: closing.dx,
              );
        target = Offset(
          edge != null
              ? edge - origin.dx
              : (closing.dx > 0 ? ink.left : ink.right - 1),
          last.dy,
        );
      } else {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: false,
                cross: (last.dx + origin.dx).round(),
                sign: closing.dy,
              );
        target = Offset(
          last.dx,
          edge != null
              ? edge - origin.dy
              : (closing.dy > 0 ? ink.top : ink.bottom - 1),
        );
      }
      final along =
          (target.dx - last.dx) * closing.dx +
          (target.dy - last.dy) * closing.dy;
      if (along > 0) points.add(target);
    } else {
      final inkCentre = ink.center;
      final last = points.last, prior = points[points.length - 2];
      final farObj = anchors.iconNodeObjects[sinkBox];
      if (last.dy == prior.dy) {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: true,
                cross: (last.dy + origin.dy).round(),
                sign: last.dx >= prior.dx ? 1 : -1,
              );
        points[points.length - 1] = Offset(
          edge != null ? edge - origin.dx : inkCentre.dx,
          last.dy,
        );
      } else {
        final edge = farObj == null
            ? null
            : primIconInkEdge(
                farObj,
                horizontal: false,
                cross: (last.dx + origin.dx).round(),
                sign: last.dy >= prior.dy ? 1 : -1,
              );
        points[points.length - 1] = Offset(
          last.dx,
          edge != null ? edge - origin.dy : inkCentre.dy,
        );
      }
    }
  }

  void _trimEndToFurniture(
    ViWire wire,
    List<Offset> points,
    _BdWireAnchors anchors, {
    required bool head,
  }) {
    final index = head ? 0 : wire.endpointAnchors.length - 1;
    final anchor = wire.endpointAnchors[index];
    if (anchor == null || anchor.width <= 0 || anchor.height <= 0) {
      return;
    }
    final anchorRect = _toCanvas(anchor);
    if (anchors.iconNodeRects.contains(anchorRect)) return;
    final end = head ? points.first : points.last;
    final next = head ? points[1] : points[points.length - 2];
    if (!anchorRect.contains(end)) return;
    final horizontal = end.dy == next.dy;
    if (!horizontal && end.dx != next.dx) return;
    final sign = horizontal ? (next.dx - end.dx).sign : (next.dy - end.dy).sign;
    if (sign == 0) return;
    double? best;
    for (final furniture in anchors.furnitureRects) {
      if (furniture.left < anchorRect.left ||
          furniture.top < anchorRect.top ||
          furniture.right > anchorRect.right ||
          furniture.bottom > anchorRect.bottom) {
        continue;
      }
      if (horizontal
          ? end.dy < furniture.top || end.dy >= furniture.bottom
          : end.dx < furniture.left || end.dx >= furniture.right) {
        continue;
      }
      if (furniture.contains(end)) return;
      final near = horizontal
          ? (sign > 0 ? furniture.left : furniture.right - 1)
          : (sign > 0 ? furniture.top : furniture.bottom - 1);
      final along = (near - (horizontal ? end.dx : end.dy)) * sign;
      final limit =
          ((horizontal ? next.dx : next.dy) - (horizontal ? end.dx : end.dy)) *
          sign;
      if (along <= 0 || along > limit) continue;
      if (best == null ||
          along < (best - (horizontal ? end.dx : end.dy)) * sign) {
        best = near;
      }
    }
    if (best == null) return;
    final trimmed = horizontal ? Offset(best, end.dy) : Offset(end.dx, best);
    if (head) {
      points[0] = trimmed;
    } else {
      points[points.length - 1] = trimmed;
    }
  }

  void _straightStubLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.pointCount != 2 ||
        wire.route?.direction == null ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    final dir = wire.route!.direction!;
    final horizontal = dir.dy == 0;
    final crossCandidates = <int>{};
    for (var endpointIndex = 0; endpointIndex < 2; endpointIndex++) {
      final attach = wire.endpointAttachRects[endpointIndex];
      if (attach != null &&
          attach.right > attach.left &&
          attach.bottom > attach.top) {
        crossCandidates.add(
          horizontal
              ? attach.top + (attach.bottom - attach.top) ~/ 2
              : attach.left + (attach.right - attach.left) ~/ 2,
        );
      } else {
        final terminal = bdPrimTerminalOf(
          scene.diagram,
          wire.endpointOids[endpointIndex],
        );
        final coord = horizontal ? terminal?.y : terminal?.x;
        if (coord != null) crossCandidates.add(coord);
      }
    }
    if (crossCandidates.length == 1) {
      final cross = crossCandidates.single;
      final lowEnd = dir.dx > 0 || dir.dy > 0 ? 0 : 1;
      final lowBound = _stubVisibleBound(
        wire,
        lowEnd,
        horizontal: horizontal,
        cross: cross,
        lowSide: true,
      );
      final highBound = _stubVisibleBound(
        wire,
        1 - lowEnd,
        horizontal: horizontal,
        cross: cross,
        lowSide: false,
      );
      if (lowBound != null && highBound != null && lowBound <= highBound) {
        legs.add(
          horizontal
              ? [
                  Offset(lowBound - origin.dx, cross - origin.dy),
                  Offset(highBound - origin.dx, cross - origin.dy),
                ]
              : [
                  Offset(cross - origin.dx, lowBound - origin.dy),
                  Offset(cross - origin.dx, highBound - origin.dy),
                ],
        );
      }
    }
  }

  int? _stubVisibleBound(
    ViWire wire,
    int endpointIndex, {
    required bool horizontal,
    required int cross,
    required bool lowSide,
  }) {
    final attach = wire.endpointAttachRects[endpointIndex];
    if (attach != null &&
        attach.right > attach.left &&
        attach.bottom > attach.top) {
      return horizontal
          ? (lowSide ? attach.right : attach.left - 1)
          : (lowSide ? attach.bottom : attach.top - 1);
    }
    final dco = scene.diagram.byId[wire.endpointOids[endpointIndex]];
    final owner = dco?.parentOid == null
        ? null
        : scene.diagram.byId[dco!.parentOid!];
    if (owner == null) return null;
    final edge = primIconInkEdge(
      owner,
      horizontal: horizontal,
      cross: cross,
      sign: lowSide ? -1 : 1,
    );
    if (edge != null) return lowSide ? edge : edge - 1;
    final bounds = owner.absBounds;
    if (bounds == null) return null;
    final inSpan = horizontal
        ? cross >= bounds.top && cross < bounds.bottom
        : cross >= bounds.left && cross < bounds.right;
    if (!inSpan) return null;
    return horizontal
        ? (lowSide ? bounds.right : bounds.left - 1)
        : (lowSide ? bounds.bottom : bounds.top - 1);
  }

  void _threePointStubLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.pointCount != 3 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != 1 ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    final route = wire.route!;
    final dir = route.direction!;
    for (final (tail, head) in [(0, 1), (1, 0)]) {
      final attach = wire.endpointAttachRects[tail];
      if (attach == null ||
          attach.right <= attach.left ||
          attach.bottom <= attach.top) {
        continue;
      }
      if (wire.endpointAttachRects[head] != null) continue;
      final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[head]);
      final headObj = scene.diagram.byId[wire.endpointOids[head]];
      final headOwner = headObj?.parentOid == null
          ? null
          : scene.diagram.byId[headObj!.parentOid!];
      final headBox = headOwner?.absBounds;
      final closingSign = bdRouteClosingSign(route, dir);
      if (headOwner == null || headBox == null) break;
      final start = (
        x: attach.left + (attach.right - attach.left) ~/ 2,
        y: attach.top + (attach.bottom - attach.top) ~/ 2,
      );
      final bend = (
        x: start.x + dir.dx * route.segmentLengths[0],
        y: start.y + dir.dy * route.segmentLengths[0],
      );
      final closingHorizontal = dir.dx == 0;
      final arrivalCross = closingHorizontal ? bend.y : bend.x;
      final catalogued = closingHorizontal ? terminal?.y : terminal?.x;
      final visStart = (
        x: dir.dx == 0
            ? start.x
            : (dir.dx > 0 ? attach.right : attach.left - 1),
        y: dir.dy == 0
            ? start.y
            : (dir.dy > 0 ? attach.bottom : attach.top - 1),
      );
      if (catalogued != null && catalogued == arrivalCross) {
        final edge = primIconInkEdge(
          headOwner,
          horizontal: closingHorizontal,
          cross: arrivalCross,
          sign: closingSign,
        );
        if (edge == null) break;
        final far = edge - closingSign;
        legs.add([
          Offset(visStart.x - origin.dx, visStart.y - origin.dy),
          Offset(bend.x - origin.dx, bend.y - origin.dy),
          closingHorizontal
              ? Offset(far - origin.dx, bend.y - origin.dy)
              : Offset(bend.x - origin.dx, far - origin.dy),
        ]);
        break;
      }
      final primCoord = dir.dx == 0 ? terminal?.y : terminal?.x;
      if (primCoord != null) {
        final closingCross =
            primCoord + (dir.dx + dir.dy) * route.segmentLengths[0];
        final attachCross = dir.dx == 0 ? start.y : start.x;
        final signToAttach = dir.dx == 0
            ? (start.x >= headBox.right
                  ? 1
                  : start.x < headBox.left
                  ? -1
                  : 0)
            : (start.y >= headBox.bottom
                  ? 1
                  : start.y < headBox.top
                  ? -1
                  : 0);
        if (closingCross == attachCross && closingSign == signToAttach) {
          final edge = primIconInkEdge(
            headOwner,
            horizontal: dir.dx == 0,
            cross: closingCross,
            sign: -closingSign,
          );
          if (edge == null) break;
          final nearAttach = dir.dx == 0
              ? (closingSign > 0 ? attach.left - 1 : attach.right)
              : (closingSign > 0 ? attach.top - 1 : attach.bottom);
          legs.add([
            dir.dx == 0
                ? Offset(edge - origin.dx, closingCross - origin.dy)
                : Offset(closingCross - origin.dx, edge - origin.dy),
            dir.dx == 0
                ? Offset(nearAttach - origin.dx, closingCross - origin.dy)
                : Offset(closingCross - origin.dx, nearAttach - origin.dy),
          ]);
          break;
        }
      }
      if (terminal == null &&
          bend.x > headBox.left &&
          bend.x < headBox.right &&
          bend.y > headBox.top &&
          bend.y < headBox.bottom) {
        legs.add([
          Offset(visStart.x - origin.dx, visStart.y - origin.dy),
          Offset(bend.x - origin.dx, bend.y - origin.dy),
        ]);
        break;
      }
      break;
    }
  }

  void _walkedRouteLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.routePoints != null ||
        (wire.route?.pointCount ?? 0) < 3 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != wire.route!.pointCount - 2 ||
        wire.endpointOids.length != 2) {
      return;
    }
    final route = wire.route!;
    final headTerminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[0]);
    final headAttach = wire.endpointAttachRects[0];
    if (headTerminal?.x != null &&
        headTerminal?.y != null &&
        (headAttach == null ||
            headAttach.right <= headAttach.left ||
            headAttach.bottom <= headAttach.top)) {
      final walk = walkRouteBends(
        route,
        origin: (x: headTerminal!.x!, y: headTerminal.y!),
      )!;
      final bends = walk.points;
      final lastBend = bends.last;
      final closingHorizontal = walk.closingHorizontal;
      final closingSign = walk.closingSign;
      final arrivalCross = closingHorizontal ? lastBend.y : lastBend.x;
      int? terminus;
      final farAttach = wire.endpointAttachRects[1];
      if (farAttach != null &&
          farAttach.right > farAttach.left &&
          farAttach.bottom > farAttach.top) {
        final cross = closingHorizontal
            ? farAttach.top + (farAttach.bottom - farAttach.top) ~/ 2
            : farAttach.left + (farAttach.right - farAttach.left) ~/ 2;
        if (cross == arrivalCross) {
          terminus = closingHorizontal
              ? (closingSign > 0 ? farAttach.left - 1 : farAttach.right)
              : (closingSign > 0 ? farAttach.top - 1 : farAttach.bottom);
        }
      } else {
        final farTerminal = bdPrimTerminalOf(
          scene.diagram,
          wire.endpointOids[1],
        );
        var farCross = closingHorizontal ? farTerminal?.y : farTerminal?.x;
        if (farCross == null) {
          for (final candidate
              in scene.diagram
                      .dcoChildTerminalAttach(wire.endpointOids[1])
                      ?.candidates ??
                  const <ViPoint>[]) {
            final cross = closingHorizontal ? candidate.y : candidate.x;
            if (cross == arrivalCross) {
              farCross = cross;
              break;
            }
          }
        }
        final farObj = scene.diagram.byId[wire.endpointOids[1]];
        final farOwner = farObj?.parentOid == null
            ? null
            : scene.diagram.byId[farObj!.parentOid!];
        final farBox = farOwner?.absBounds;
        if (farCross == arrivalCross && farBox != null) {
          final edge = primIconInkEdge(
            farOwner!,
            horizontal: closingHorizontal,
            cross: arrivalCross,
            sign: closingSign,
          );
          terminus = edge != null
              ? edge - closingSign
              : (closingSign > 0
                    ? (closingHorizontal ? farBox.left : farBox.top) - 1
                    : (closingHorizontal ? farBox.right : farBox.bottom));
        }
      }
      if (terminus != null &&
          (terminus - (closingHorizontal ? lastBend.x : lastBend.y)) *
                  closingSign >=
              0) {
        legs.add([
          for (final bend in bends)
            Offset(bend.x - origin.dx, bend.y - origin.dy),
          closingHorizontal
              ? Offset(terminus - origin.dx, lastBend.y - origin.dy)
              : Offset(lastBend.x - origin.dx, terminus - origin.dy),
        ]);
      }
    }
  }

  void _coveredAttachWalkLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.routePoints != null ||
        (wire.route?.pointCount ?? 0) < 4 ||
        wire.route?.direction == null ||
        wire.route!.segmentLengths.length != wire.route!.pointCount - 2 ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    final route = wire.route!;
    for (final (tail, head) in [(0, 1), (1, 0)]) {
      final attach = wire.endpointAttachRects[tail];
      if (attach == null ||
          attach.right <= attach.left ||
          attach.bottom <= attach.top) {
        continue;
      }
      if (wire.endpointAttachRects[head] != null) continue;
      final walk = walkRouteBends(
        route,
        origin: (
          x: attach.left + (attach.right - attach.left) ~/ 2,
          y: attach.top + (attach.bottom - attach.top) ~/ 2,
        ),
      )!;
      var covered = true;
      for (var index = 1; index < walk.points.length; index++) {
        final bend = walk.points[index];
        covered =
            covered &&
            bend.x >= attach.left &&
            bend.x < attach.right &&
            bend.y >= attach.top &&
            bend.y < attach.bottom;
      }
      if (!covered) break;
      final lastBend = walk.points.last;
      final closingHorizontal = walk.closingHorizontal;
      final closingSign = walk.closingSign;
      final arrivalCross = closingHorizontal ? lastBend.y : lastBend.x;
      final terminal = bdPrimTerminalOf(scene.diagram, wire.endpointOids[head]);
      final catalogued = closingHorizontal ? terminal?.y : terminal?.x;
      if (catalogued == null || catalogued != arrivalCross) break;
      final headObj = scene.diagram.byId[wire.endpointOids[head]];
      final headOwner = headObj?.parentOid == null
          ? null
          : scene.diagram.byId[headObj!.parentOid!];
      if (headOwner == null) break;
      final edge = primIconInkEdge(
        headOwner,
        horizontal: closingHorizontal,
        cross: arrivalCross,
        sign: closingSign,
      );
      if (edge == null) break;
      final terminus = edge - closingSign;
      final border = closingHorizontal
          ? (closingSign > 0 ? attach.right : attach.left - 1)
          : (closingSign > 0 ? attach.bottom : attach.top - 1);
      if ((terminus - border) * closingSign < 0) break;
      legs.add(
        closingHorizontal
            ? [
                Offset(border - origin.dx, arrivalCross - origin.dy),
                Offset(terminus - origin.dx, arrivalCross - origin.dy),
              ]
            : [
                Offset(arrivalCross - origin.dx, border - origin.dy),
                Offset(arrivalCross - origin.dx, terminus - origin.dy),
              ],
      );
      break;
    }
  }

  void _containerFaceLeg(ViWire wire, List<List<Offset>> legs) {
    if (wire.route?.direction == null ||
        wire.endpointOids.length != 2 ||
        wire.endpointAttachRects.length < 2) {
      return;
    }
    const exactMax = 16, containerMin = 17;
    final route = wire.route!;
    final dir = route.direction!;
    final closingHorizontal = route.pointCount == 2
        ? dir.isHorizontal
        : (route.pointCount.isEven ? dir.isHorizontal : !dir.isHorizontal);
    final closingSign = route.pointCount > 2 && route.jointSigns.isEmpty
        ? 0
        : bdRouteClosingSign(route, dir);
    final dirTowardContainer =
        route.pointCount == 2 ||
        (dir.isHorizontal == closingHorizontal &&
            (dir.dx + dir.dy) == -closingSign);
    for (final (exactEnd, containerEnd) in [(0, 1), (1, 0)]) {
      if (closingSign == 0 || !dirTowardContainer) break;
      final exact = wire.endpointAttachRects[exactEnd];
      final container = wire.endpointAttachRects[containerEnd];
      if (exact == null || container == null) continue;
      if (exact.width <= 0 ||
          exact.width > exactMax ||
          exact.height <= 0 ||
          exact.height > exactMax) {
        continue;
      }
      if (container.width < containerMin || container.height < containerMin) {
        continue;
      }
      final attachPoint = scene.diagram.wireAttachPoint(
        wire.endpointOids[exactEnd],
      );
      if (attachPoint == null) continue;
      final int toExact, cross, faceLo, faceHi;
      if (closingHorizontal) {
        cross = attachPoint.y;
        if (cross <= container.top || cross >= container.bottom) continue;
        if (container.right <= exact.left) {
          toExact = 1;
          faceLo = container.right;
          faceHi = exact.left - 1;
        } else if (exact.right <= container.left) {
          toExact = -1;
          faceLo = exact.right;
          faceHi = container.left - 1;
        } else {
          continue;
        }
      } else {
        cross = attachPoint.x;
        if (cross <= container.left || cross >= container.right) continue;
        if (container.bottom <= exact.top) {
          toExact = 1;
          faceLo = container.bottom;
          faceHi = exact.top - 1;
        } else if (exact.bottom <= container.top) {
          toExact = -1;
          faceLo = exact.bottom;
          faceHi = container.top - 1;
        } else {
          continue;
        }
      }
      final wantSign = route.pointCount == 2
          ? (exactEnd == 0 ? -toExact : toExact)
          : toExact;
      if (closingSign != wantSign || faceLo > faceHi) continue;
      var runLo = faceLo, runHi = faceHi;
      for (final shell in scene.drawable) {
        final bounds = shell.absBounds;
        if (shell.objectClass != HeapObjectClass.caseOrSequence ||
            bounds == null ||
            bounds.left != container.left ||
            bounds.top != container.top ||
            bounds.right != container.right ||
            bounds.bottom != container.bottom) {
          continue;
        }
        int? face;
        for (final wrap in bdArrayShellWrapRects(scene.diagram, shell.oid)) {
          final int wrapLo, wrapHi, wrapFace;
          if (closingHorizontal) {
            wrapLo = wrap.top;
            wrapHi = wrap.bottom;
            wrapFace = toExact == 1 ? wrap.right : wrap.left;
          } else {
            wrapLo = wrap.left;
            wrapHi = wrap.right;
            wrapFace = toExact == 1 ? wrap.bottom : wrap.top;
          }
          if (cross <= wrapLo || cross >= wrapHi) continue;
          face = face == null
              ? wrapFace
              : (toExact == 1
                    ? math.max(face, wrapFace)
                    : math.min(face, wrapFace));
        }
        if (face != null) {
          if (toExact == 1) {
            runLo = face;
          } else {
            runHi = face - 1;
          }
        }
        break;
      }
      if (runLo > runHi) continue;
      legs.add(
        closingHorizontal
            ? [
                Offset(runLo - origin.dx, cross - origin.dy),
                Offset(runHi - origin.dx, cross - origin.dy),
              ]
            : [
                Offset(cross - origin.dx, runLo - origin.dy),
                Offset(cross - origin.dx, runHi - origin.dy),
              ],
      );
      break;
    }
  }

  ViWireRenderStyle _wireStrokeStyle(ViWire wire) {
    final sigType = wire.signalType;
    var style = sigType?.renderStyle;
    if (style == null) {
      final estimate = sigType?.renderStyleEstimate;
      if (estimate == ViWireRenderStyle.solid1px ||
          estimate == ViWireRenderStyle.solid2px ||
          estimate == ViWireRenderStyle.dotted) {
        style = estimate;
      }
    }
    style ??=
        (wire.elementTypeKind == ViTypeKind.boolean &&
            (sigType?.arrayDims ?? 0) == 0)
        ? ViWireRenderStyle.dotted
        : ((sigType?.arrayDims ?? 0) >= 1
              ? ViWireRenderStyle.solid2px
              : ViWireRenderStyle.solid1px);
    return style;
  }

  void _strokeWireLegs(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    List<List<Offset>> legs,
    List<Offset> junctions,
    List<_BdWireSeg> drawn, {
    required bool errorBraid,
  }) {
    final (bandLo, bandHi) = bdWireStrokeBand(style);
    final mine = <_BdWireSeg>[];
    for (final leg in legs) {
      for (var segmentIndex = 1; segmentIndex < leg.length; segmentIndex++) {
        final start = leg[segmentIndex - 1], end = leg[segmentIndex];
        if (start == end) continue;
        final horizontal = start.dy == end.dy;
        var runLo =
            (horizontal
                    ? math.min(start.dx, end.dx)
                    : math.min(start.dy, end.dy))
                .floor();
        var runHi =
            (horizontal
                    ? math.max(start.dx, end.dx)
                    : math.max(start.dy, end.dy))
                .floor();
        final cross = (horizontal ? start.dy : start.dx).floor();
        if (const {
              ViWireRenderStyle.solid1px,
              ViWireRenderStyle.solid2px,
              ViWireRenderStyle.dotted,
              ViWireRenderStyle.zigzag,
              ViWireRenderStyle.chainLink,
              ViWireRenderStyle.chainLinkWide,
            }.contains(style) ||
            (style == ViWireRenderStyle.braid && horizontal)) {
          for (final neighbour in [
            if (segmentIndex >= 2) leg[segmentIndex - 2],
            if (segmentIndex + 1 < leg.length) leg[segmentIndex + 1],
          ]) {
            final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
            if (nCross + bandLo < runLo) runLo = nCross + bandLo;
            if (nCross + bandHi > runHi) runHi = nCross + bandHi;
          }
        }
        if (style == ViWireRenderStyle.braid && !horizontal) {
          for (final neighbour in [
            if (segmentIndex >= 2) leg[segmentIndex - 2],
            if (segmentIndex + 1 < leg.length) leg[segmentIndex + 1],
          ]) {
            final nCross = (horizontal ? neighbour.dx : neighbour.dy).floor();
            if ((nCross - runLo).abs() <= 1) runLo = nCross + 2;
            if ((runHi - nCross).abs() <= 1) runHi = nCross - 2;
          }
        }
        if (style == ViWireRenderStyle.braid && horizontal) {
          for (final (vertex, other) in [
            if (segmentIndex >= 2) (start, end),
            if (segmentIndex + 1 < leg.length) (end, start),
          ]) {
            final bendX = vertex.dx.floor();
            final farX = bendX - (other.dx > vertex.dx ? 1 : -1);
            final isJunction = junctions.any(
              (junction) =>
                  junction.dx.floor() == bendX && junction.dy.floor() == cross,
            );
            if (!isJunction) {
              canvas.drawRect(
                Rect.fromLTWH(farX * 1.0, cross * 1.0, 1, 1),
                fill,
              );
            }
          }
        }
        final gaps = <(int, int)>[];
        for (final earlier in drawn) {
          if (earlier.horizontal == horizontal) continue;
          if (earlier.bandLo > runLo &&
              earlier.bandHi < runHi &&
              cross + bandLo > earlier.lo &&
              cross + bandHi < earlier.hi) {
            gaps.add((earlier.bandLo - 1, earlier.bandHi + 1));
          }
        }
        _strokeSegment(
          canvas,
          fill,
          style,
          horizontal,
          runLo,
          runHi,
          cross,
          gaps,
          errorBraid: errorBraid,
        );
        mine.add((
          horizontal: horizontal,
          lo: runLo,
          hi: runHi,
          bandLo: cross + bandLo,
          bandHi: cross + bandHi,
        ));
      }
    }
    drawn.addAll(mine);
  }

  void _drawWireJunctionDot(
    Canvas canvas,
    Offset center,
    Paint fill,
    (int, int) band, {
    ViWireRenderStyle? style,
    bool errorBraid = false,
  }) {
    final cx = center.dx.floorToDouble();
    final cy = center.dy.floorToDouble();
    final ox = origin.dx.round(), oy = origin.dy.round();
    final (bandLo, bandHi) = band;
    if (style == ViWireRenderStyle.braid) {
      if (errorBraid) {
        final olive = _solidNoAa(const Color(0xFF666600));
        final yellow = _solidNoAa(const Color(0xFFFFFF00));
        final black = _solidNoAa(Colors.black);
        const rows = ['o###o', '###W#', 'WWWWW', 'WWWWW', 'o###o', '.ooo.'];
        for (var r = 0; r < rows.length; r++) {
          for (var c = 0; c < 5; c++) {
            final ch = rows[r][c];
            if (ch == '.') continue;
            final x = (cx + ox - 2 + c).toInt(), y = (cy + oy - 2 + r).toInt();
            final paint = ch == 'o'
                ? olive
                : ch == '#'
                ? black
                : ((x + y + 1) % 4 < 2 ? yellow : black);
            canvas.drawRect(Rect.fromLTWH(cx - 2 + c, cy - 2 + r, 1, 1), paint);
          }
        }
      } else {
        final white = _solidNoAa(Colors.white);
        const taper = [
          '...###...',
          '..#####..',
          '#########',
          '.........',
          '#########',
          '..#####..',
          '...###...',
        ];
        for (var r = 0; r < taper.length; r++) {
          final dy = r - 3;
          for (var c = 0; c < 9; c++) {
            if (taper[r][c] == '.') continue;
            final dx = c - 4;
            final x = (cx + ox + dx).toInt(), y = (cy + oy + dy).toInt();
            final flank = dy == -1 || dy == 1;
            final hole = flank && dx.abs() <= 1 && (x + y) % 4 % 3 == 0;
            canvas.drawRect(
              Rect.fromLTWH(cx + dx, cy + dy, 1, 1),
              hole ? white : fill,
            );
          }
        }
      }
      return;
    }
    final cycle = style == null ? null : kBdWireStrokeCycles[style];
    final phaseBase = style == null ? null : kBdWireCyclePhase[style];
    final capture = this.style.wireCycleOffset;
    bool punched(int cxp, int cyp) {
      final x = cxp + ox, y = cyp + oy;
      if (style == ViWireRenderStyle.dotted ||
          style == ViWireRenderStyle.dottedAlternating) {
        return (x + y).isOdd;
      }
      if (cycle == null || phaseBase == null || cycle.length != 4) {
        return false;
      }
      return (x + (((y + capture.y) & 1) << 1) + phaseBase + capture.x) % 4 ==
          0;
    }

    final diamond =
        style == ViWireRenderStyle.solid2px ||
        (bandLo == -1 && bandHi == 0 && cycle != null && cycle.length == 4);
    if (!diamond) {
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          if (dx.abs() == 2 && dy.abs() == 2) continue;
          final x = (cx + dx).toInt(), y = (cy + dy).toInt();
          if (style != ViWireRenderStyle.solid1px && punched(x, y)) continue;
          canvas.drawRect(Rect.fromLTWH(cx + dx, cy + dy, 1, 1), fill);
        }
      }
      return;
    }
    for (var dy = bandLo - 2; dy <= bandHi + 2; dy++) {
      final outside = dy < bandLo
          ? bandLo - dy
          : dy > bandHi
          ? dy - bandHi
          : 0;
      final reach = 2 - outside;
      final left = cx + bandLo - reach;
      final width = bandHi - bandLo + 1 + 2 * reach;
      if (style == ViWireRenderStyle.solid2px) {
        canvas.drawRect(
          Rect.fromLTWH(left, cy + dy, width.toDouble(), 1),
          fill,
        );
        continue;
      }
      for (var i = 0; i < width; i++) {
        final x = (left + i).toInt(), y = (cy + dy).toInt();
        final dx = x - cx.toInt();
        bool hole;
        if (dy >= bandLo && dy <= bandHi) {
          hole = dx >= -2 && dx <= 1 && punched(x, y);
        } else if (dy == bandLo - 1 || dy == bandHi + 1) {
          hole = dx >= bandLo && dx <= bandHi && punched(x, y);
        } else {
          hole = false;
        }
        if (hole) continue;
        canvas.drawRect(Rect.fromLTWH(left + i, cy + dy, 1, 1), fill);
      }
    }
  }

  void _strokeSegment(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    bool horizontal,
    int lo,
    int hi,
    int cross,
    List<(int, int)> gaps, {
    bool errorBraid = false,
  }) {
    gaps.sort((x, y) => x.$1.compareTo(y.$1));
    var v = lo;
    for (final (gLo, gHi) in [...gaps, (hi + 1, hi + 1)]) {
      final end = math.min(hi, gLo - 1);
      if (v <= end) {
        _strokeRun(
          canvas,
          fill,
          style,
          horizontal,
          v,
          end,
          cross,
          errorBraid: errorBraid,
        );
      }
      if (gHi + 1 > v) v = gHi + 1;
    }
  }

  void _strokeRun(
    Canvas canvas,
    Paint fill,
    ViWireRenderStyle style,
    bool horizontal,
    int lo,
    int hi,
    int cross, {
    bool errorBraid = false,
  }) {
    final ox = origin.dx.round(), oy = origin.dy.round();
    final captureX = this.style.wireCycleOffset.x;
    Rect px(int along, int band) => horizontal
        ? Rect.fromLTWH(along.toDouble(), (cross + band).toDouble(), 1, 1)
        : Rect.fromLTWH((cross + band).toDouble(), along.toDouble(), 1, 1);
    Rect span(int bandLo, int bandHi) => horizontal
        ? Rect.fromLTRB(
            lo.toDouble(),
            (cross + bandLo).toDouble(),
            hi + 1.0,
            cross + bandHi + 1.0,
          )
        : Rect.fromLTRB(
            (cross + bandLo).toDouble(),
            lo.toDouble(),
            cross + bandHi + 1.0,
            hi + 1.0,
          );
    (int, int) abs(int along, int band) {
      final canvasX = horizontal ? along : cross + band;
      final canvasY = horizontal ? cross + band : along;
      return (canvasX + ox, canvasY + oy);
    }

    bool stringTextureInk(int x, int y) =>
        (x + ((y & 1) << 1) + captureX) % 4 != 0;

    bool braidTextureInk(int x, int y) {
      final m = (x + y) % 4;
      return m == 1 || m == 2;
    }

    switch (style) {
      case ViWireRenderStyle.solid1px:
        canvas.drawRect(span(0, 0), fill);
      case ViWireRenderStyle.solid2px:
        canvas.drawRect(span(-1, 0), fill);
      case ViWireRenderStyle.hollowDouble:
        canvas.drawRect(span(-1, -1), fill);
        canvas.drawRect(span(1, 1), fill);
      case ViWireRenderStyle.dotted:
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          if ((x + y).isEven) canvas.drawRect(px(v, 0), fill);
        }
      case ViWireRenderStyle.dottedAlternating:
        for (var v = lo; v <= hi; v++) {
          for (final band in const [-1, 0]) {
            final (x, y) = abs(v, band);
            if ((x + y).isEven) canvas.drawRect(px(v, band), fill);
          }
        }
      case ViWireRenderStyle.zigzag ||
          ViWireRenderStyle.chainLink ||
          ViWireRenderStyle.chainLinkWide:
        final (bandLo, bandHi) = switch (style) {
          ViWireRenderStyle.zigzag => (-1, 0),
          ViWireRenderStyle.chainLink => (-1, 1),
          _ => (-2, 1),
        };
        for (var v = lo; v <= hi; v++) {
          for (var band = bandLo; band <= bandHi; band++) {
            final (x, y) = abs(v, band);
            if (stringTextureInk(x, y)) canvas.drawRect(px(v, band), fill);
          }
        }
      case ViWireRenderStyle.braid when errorBraid:
        final olive = _solidNoAa(const Color(0xFF666600));
        final yellow = _solidNoAa(const Color(0xFFFFFF00));
        final black = _solidNoAa(Colors.black);
        canvas.drawRect(span(-1, -1), olive);
        canvas.drawRect(span(1, 1), olive);
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          canvas.drawRect(px(v, 0), braidTextureInk(x, y) ? black : yellow);
        }
      case ViWireRenderStyle.braid:
        canvas.drawRect(span(-1, -1), fill);
        canvas.drawRect(span(1, 1), fill);
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          final ink = horizontal
              ? (x + ((y & 1) << 1) + captureX) % 4 >= 2
              : braidTextureInk(x, y);
          if (ink) canvas.drawRect(px(v, 0), fill);
        }
      case ViWireRenderStyle.braidWide:
        canvas.drawRect(span(-2, -2), fill);
        canvas.drawRect(span(1, 1), fill);
        for (var v = lo; v <= hi; v++) {
          for (final band in const [-1, 0]) {
            final (x, y) = abs(v, band);
            if (braidTextureInk(x, y)) canvas.drawRect(px(v, band), fill);
          }
        }
      default:
        final cycle = horizontal ? kBdWireStrokeCycles[style] : null;
        if (cycle == null) {
          canvas.drawRect(span(0, 0), fill);
          return;
        }
        for (var v = lo; v <= hi; v++) {
          final (x, y) = abs(v, 0);
          final mask = cycle[(x + ((y & 1) << 1) + 1) % cycle.length];
          for (var bit = 0; bit < 5; bit++) {
            if ((mask >> bit) & 1 != 0) {
              canvas.drawRect(px(v, bit - 2), fill);
            }
          }
        }
    }
  }
}
