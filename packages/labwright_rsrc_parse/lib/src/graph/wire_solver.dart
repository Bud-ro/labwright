part of '../graph.dart';

typedef _RoutedPoints = ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack});

typedef _RoutedTree = ({ViWireRouteTree tree, WireRouteFidelity fidelity});

_RoutedPoints _closedPoints(List<ViPoint> points) =>
    (points: points, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);

_RoutedPoints _walkedPoints(({List<ViPoint> points, ViStep? closingStep, ViStep? headSlack}) walk) =>
    (points: walk.points, fidelity: WireRouteFidelity.walked, closingStep: walk.closingStep, headSlack: walk.headSlack);

class _WireEndpoint {
  const _WireEndpoint({
    required this.oid,
    required this.anchor,
    required this.attachRect,
    required this.attach,
    required this.altAttach,
    required this.stripTarget,
    required this.dcoChildAttach,
  });

  final int oid;

  final HeapRect? anchor;

  final HeapRect? attachRect;

  final ViPoint? attach;

  final ViPoint? altAttach;

  final ViPoint? stripTarget;

  final ({List<ViPoint> candidates, bool wideRow})? dcoChildAttach;

  bool get isAnchored => attach != null;

  List<ViPoint> get sources => [?attach, ?altAttach];

  List<ViPoint> get targets => [?stripTarget, ?attach, ?altAttach];

  bool get usesDcoChild => attach == null && (dcoChildAttach?.candidates.isNotEmpty ?? false);

  List<ViPoint> get dcoChildCandidates => dcoChildAttach?.candidates ?? const [];
}

bool _leavesReach(List<ViPoint> leaves, List<List<ViPoint>> candidatesPerEndpoint) {
  final remaining = <ViPoint, int>{};
  for (final leaf in leaves) {
    remaining.update(leaf, (count) => count + 1, ifAbsent: () => 1);
  }
  for (final candidates in candidatesPerEndpoint) {
    if (candidates.isEmpty) continue;
    ViPoint? match;
    for (final candidate in candidates) {
      if (remaining.containsKey(candidate)) {
        match = candidate;
        break;
      }
    }
    if (match == null) return false;
    final count = remaining[match]!;
    if (count == 1) {
      remaining.remove(match);
    } else {
      remaining[match] = count - 1;
    }
  }
  return true;
}

extension on ViDiagram {
  ViWire _buildWire(ViHeapObject signal) {
    final raw = signal.wireTableRaw;
    final route = raw == null ? null : decodeWireRoute(raw);
    final branchRoute = raw == null || signal.refs.length < 3 ? null : decodeWireBranchRoute(raw);
    final endpoints = [for (final oid in signal.refs) _endpoint(oid)];
    final points = route == null || endpoints.length != 2 ? null : _routePointsFor(route, endpoints);
    return ViWire(
      signalOid: signal.oid,
      endpointOids: List<int>.of(signal.refs),
      endpointAnchors: [for (final endpoint in endpoints) endpoint.anchor],
      endpointAttachRects: [for (final endpoint in endpoints) endpoint.attachRect],
      route: route,
      routePoints: points?.points,
      routePointsFidelity: points?.fidelity,
      routeClosingStep: points?.closingStep,
      routeHeadSlack: points?.headSlack,
      branchRoute: branchRoute,
      routeTreeBuilder: branchRoute == null
          ? null
          : () => _shippableRouteTree(branchRoute, endpoints) ?? _dcoChildRouteTree(branchRoute, endpoints),
      signalType: signal.lastSignalKind == null ? null : ViSignalType(signal.lastSignalKind!),
    );
  }

  _WireEndpoint _endpoint(int oid) {
    final constantBounds = endpointConstantBounds(oid);
    final attachRect = endpointTerminalBounds(oid) ?? constantBounds;
    final attach = _attachPointFrom(attachRect, oid);
    final elementBounds = endpointConstantElementBounds(oid);
    return _WireEndpoint(
      oid: oid,
      anchor: constantBounds ?? _boundedOwnerBounds(oid),
      attachRect: attachRect,
      attach: attach,
      altAttach: elementBounds == null || attach == null ? null : _attachPointFrom(elementBounds, oid),
      stripTarget: _stripFarTarget(oid, attachRect, attach),
      dcoChildAttach: dcoChildTerminalAttach(oid),
    );
  }

  _RoutedPoints? _routePointsFor(ViWireRoute route, List<_WireEndpoint> endpoints) {
    final (start, end) = (endpoints[0], endpoints[1]);
    for (final target in end.targets) {
      for (final source in start.sources) {
        final closed = ViDiagram._closedRoutePoints(route, source, target);
        if (closed != null) return _closedPoints(closed);
      }
    }
    final int anchoredIndex;
    if (start.isAnchored && !end.isAnchored) {
      anchoredIndex = 0;
    } else if (end.isAnchored && !start.isAnchored) {
      anchoredIndex = 1;
    } else {
      return _dcoChildTierPoints(route, endpoints);
    }
    final anchored = endpoints[anchoredIndex];
    final farBox = endpoints[1 - anchoredIndex].anchor;
    if (_exactAttach(anchored.oid) && farBox != null) {
      final walked = walkOneAnchoredRoute(
        route,
        anchor: anchored.attach!,
        anchoredIndex: anchoredIndex,
        farBox: farBox,
      );
      if (walked != null) return _walkedPoints(walked);
    }
    return _dcoChildTierPoints(route, endpoints);
  }

  _RoutedPoints? _dcoChildTierPoints(ViWireRoute route, List<_WireEndpoint> endpoints) {
    final (start, end) = (endpoints[0], endpoints[1]);
    if (!start.usesDcoChild && !end.usesDcoChild) return null;
    final sources = start.usesDcoChild ? start.dcoChildCandidates : start.sources;
    final targets = end.usesDcoChild ? end.dcoChildCandidates : end.targets;
    for (final source in sources) {
      for (final target in targets) {
        final closed = ViDiagram._closedRoutePoints(route, source, target);
        if (closed != null) return _closedPoints(closed);
      }
    }
    final int anchoredIndex;
    if (start.usesDcoChild && start.dcoChildAttach!.wideRow && !end.isAnchored) {
      anchoredIndex = 0;
    } else if (end.usesDcoChild && end.dcoChildAttach!.wideRow && !start.isAnchored) {
      anchoredIndex = 1;
    } else {
      return null;
    }
    final farBox = endpoints[1 - anchoredIndex].anchor;
    if (farBox == null) return null;
    final walked = walkOneAnchoredRoute(
      route,
      anchor: endpoints[anchoredIndex].dcoChildCandidates.first,
      anchoredIndex: anchoredIndex,
      farBox: farBox,
    );
    return walked == null ? null : _walkedPoints(walked);
  }

  bool _exactAttach(int oid) {
    final terminal = endpointTerminal(oid);
    if (terminal == null) return endpointConstantBounds(oid) == null;
    final parent = terminal.parentOid == null ? null : byId[terminal.parentOid!];
    final frame = parent == null ? null : _boundedOwnerObject(parent);
    return frame != null && frame.category == ViObjectKind.structure;
  }

  static _RoutedTree? _shippableRouteTree(ViWireBranchRoute route, List<_WireEndpoint> endpoints) {
    if (endpoints.length < 3) return null;
    final head = endpoints[0];
    if (!head.isAnchored) return _reverseSolvedRouteTree(route, endpoints);
    final tails = endpoints.sublist(1);
    final candidates = [for (final endpoint in tails) endpoint.targets];
    final fidelity = tails.every((endpoint) => endpoint.isAnchored)
        ? WireRouteFidelity.closed
        : WireRouteFidelity.walked;
    for (final origin in head.sources) {
      final tree = walkWireBranchRoute(route, origin);
      if (tree.leaves.length != tails.length) continue;
      if (_leavesReach(tree.leaves, candidates)) return (tree: tree, fidelity: fidelity);
    }
    return null;
  }

  static _RoutedTree? _reverseSolvedRouteTree(ViWireBranchRoute route, List<_WireEndpoint> endpoints) {
    final headBox = endpoints[0].anchor;
    if (headBox == null) return null;
    final tails = endpoints.sublist(1);
    final leaves = walkWireBranchRoute(route, (x: 0, y: 0)).leaves;
    if (leaves.length != tails.length) return null;
    final seed = tails.where((endpoint) => endpoint.isAnchored).firstOrNull;
    if (seed == null) return null;
    final origins = <ViPoint>{
      for (final leaf in leaves)
        for (final candidate in seed.targets) (x: candidate.x - leaf.x, y: candidate.y - leaf.y),
    };
    final candidates = [for (final endpoint in tails) endpoint.targets];
    ViPoint? solved;
    for (final origin in origins) {
      if (!headBox.containsPoint(origin.x, origin.y)) continue;
      final placed = [for (final leaf in leaves) (x: leaf.x + origin.x, y: leaf.y + origin.y)];
      if (!_leavesReach(placed, candidates)) continue;
      if (solved != null) return null;
      solved = origin;
    }
    if (solved == null) return null;
    return (tree: walkWireBranchRoute(route, solved), fidelity: WireRouteFidelity.walked);
  }

  _RoutedTree? _dcoChildRouteTree(ViWireBranchRoute route, List<_WireEndpoint> endpoints) {
    if (endpoints.length < 3 || endpoints[0].isAnchored) return null;
    final origins = endpoints[0].dcoChildAttach?.candidates;
    if (origins == null) return null;
    final tails = endpoints.sublist(1);
    final candidates = [
      for (final endpoint in tails) [...endpoint.targets, ...endpoint.dcoChildCandidates],
    ];
    if (candidates.any((list) => list.isEmpty)) return null;
    for (final origin in origins) {
      final tree = walkWireBranchRoute(route, origin);
      if (tree.leaves.length != tails.length) continue;
      if (_leavesReach(tree.leaves, candidates)) return (tree: tree, fidelity: WireRouteFidelity.closed);
    }
    return null;
  }
}
