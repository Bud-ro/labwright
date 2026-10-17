/// The object tree of one block-diagram heap: [BdDiagram] indexes the objects by oid and
/// parent and derives one [ViWire] per `signal` object, with its endpoints, anchors and
/// decoded route.
library;

import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/obj_flags.dart';
import 'bd_object.dart';
import 'signal_type.dart';
import 'wire_route.dart';

// TODO: LabVIEW < 8.6 heaps store bounds in an absolute coordinate space that is not decoded.
bool _predatesFrameRelativeTermBounds(String? version) {
  if (version == null) return false;
  final parts = version.split('.');
  if (parts.length < 2) return false;
  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  if (major == null || minor == null) return false;
  return major < 8 || (major == 8 && minor < 6);
}

/// The objects of one `BDHb` section, indexed by oid and parent, with the wires derived from
/// its signals.
class BdDiagram extends HeapObjectTree<BdObject> {
  BdDiagram({required super.objects, super.version, super.sectionIndex});

  late final bool _predatesFrameRelativeTerms = _predatesFrameRelativeTermBounds(version);

  /// The frame objects of a structure, in heap order.
  List<BdObject> framesOf(BdObject structure) => [
    for (final child in children(structure.oid))
      if (child.objectClass == BdObjectClass.frame) child,
  ];

  /// The frame a multi-frame structure shows, null for other objects or an index past its frames.
  int? displayedFrameIndex(BdObject structure) {
    final frames = structure.frames;
    if (frames == null) return null;
    var count = 0;
    for (final child in children(structure.oid)) {
      if (child.objectClass == BdObjectClass.frame) count++;
    }
    final index = frames.visibleFrameIndex;
    return index < count ? index : null;
  }

  /// One wire per `signal` object.
  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.signal case final signal?) _buildWire(object, signal),
  ];

  ViWire _buildWire(BdObject object, BdSignal signal) {
    final raw = signal.wireTableRaw;
    final route = raw == null ? null : decodeWireRoute(raw);
    final branchRoute = raw == null || object.refs.length < 3 ? null : decodeWireBranchRoute(raw);
    final constantBounds = [for (final oid in object.refs) endpointConstantBounds(oid)];
    final attachRects = [
      for (var i = 0; i < object.refs.length; i++) endpointTerminalBounds(object.refs[i]) ?? constantBounds[i],
    ];
    final attachPoints = [
      for (var i = 0; i < object.refs.length; i++) _attachPointFrom(attachRects[i], object.refs[i]),
    ];
    final altAttachPoints = [
      for (var i = 0; i < object.refs.length; i++)
        switch (endpointConstantElementBounds(object.refs[i])) {
          null => null,
          final elem => attachPoints[i] == null ? null : _attachPointFrom(elem, object.refs[i]),
        },
    ];
    final stripTargets = [
      for (var i = 0; i < object.refs.length; i++) _stripFarTarget(object.refs[i], attachRects[i], attachPoints[i]),
    ];
    final anchors = [
      for (var i = 0; i < object.refs.length; i++) constantBounds[i] ?? _boundedOwnerBounds(object.refs[i]),
    ];
    final signalKind = signal.lastSignalKind;
    final points = route == null || object.refs.length != 2
        ? null
        : _routePointsFor(route, object.refs, attachPoints, anchors, altAttachPoints, stripTargets);
    return ViWire(
      signalOid: object.oid,
      endpointOids: List<int>.of(object.refs),
      endpointAnchors: anchors,
      endpointAttachRects: attachRects,
      route: route,
      routePoints: points?.points,
      routePointsFidelity: points?.fidelity,
      routeClosingStep: points?.closingStep,
      routeHeadSlack: points?.headSlack,
      branchRoute: branchRoute,
      routeTreeBuilder: branchRoute == null
          ? null
          : () =>
                _shippableRouteTree(branchRoute, attachPoints, altAttachPoints, stripTargets, anchors[0]) ??
                _dcoChildRouteTree(branchRoute, object.refs, attachPoints, altAttachPoints, stripTargets),
      signalType: signalKind == null ? null : ViSignalType(signalKind),
    );
  }

  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _routePointsFor(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<HeapRect?> anchors,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    for (final pair in [
      (attachPoints[0], stripTargets[1]),
      (altAttachPoints[0], stripTargets[1]),
      (attachPoints[0], attachPoints[1]),
      (altAttachPoints[0], attachPoints[1]),
      (attachPoints[0], altAttachPoints[1]),
      (altAttachPoints[0], altAttachPoints[1]),
    ]) {
      final closed = _closedRoutePoints(route, pair.$1, pair.$2);
      if (closed != null) {
        return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
      }
    }
    final int anchoredIndex;
    final ViPoint anchorPoint;
    final head = attachPoints[0], tail = attachPoints[1];
    if (head != null && tail == null) {
      anchoredIndex = 0;
      anchorPoint = head;
    } else if (tail != null && head == null) {
      anchoredIndex = 1;
      anchorPoint = tail;
    } else {
      return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
    }
    if (_exactAttach(refs[anchoredIndex])) {
      final farBox = anchors[1 - anchoredIndex];
      if (farBox != null) {
        final walked = walkOneAnchoredRoute(
          route,
          anchor: anchorPoint,
          anchoredIndex: anchoredIndex,
          farBox: farBox,
        );
        if (walked != null) {
          return (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
        }
      }
    }
    return _dcoChildTierPoints(route, refs, attachPoints, altAttachPoints, stripTargets, anchors);
  }

  ({List<ViPoint> points, WireRouteFidelity fidelity, ViStep? closingStep, ViStep? headSlack})? _dcoChildTierPoints(
    ViWireRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    List<HeapRect?> anchors,
  ) {
    final fallback = [for (final oid in refs) dcoChildTerminalAttach(oid)];
    final usesFallback = [
      for (var i = 0; i < 2; i++) attachPoints[i] == null && (fallback[i]?.candidates.isNotEmpty ?? false),
    ];
    if (!usesFallback[0] && !usesFallback[1]) return null;
    final sourceCandidates = usesFallback[0]
        ? fallback[0]!.candidates
        : [
            if (attachPoints[0] != null) attachPoints[0]!,
            if (altAttachPoints[0] != null) altAttachPoints[0]!,
          ];
    final targetCandidates = usesFallback[1]
        ? fallback[1]!.candidates
        : [
            if (stripTargets[1] != null) stripTargets[1]!,
            if (attachPoints[1] != null) attachPoints[1]!,
            if (altAttachPoints[1] != null) altAttachPoints[1]!,
          ];
    for (final source in sourceCandidates) {
      for (final target in targetCandidates) {
        final closed = _closedRoutePoints(route, source, target);
        if (closed != null) {
          return (points: closed, fidelity: WireRouteFidelity.closed, closingStep: null, headSlack: null);
        }
      }
    }
    final int anchoredIndex;
    if (usesFallback[0] && (fallback[0]?.wideRow ?? false) && attachPoints[1] == null) {
      anchoredIndex = 0;
    } else if (usesFallback[1] && (fallback[1]?.wideRow ?? false) && attachPoints[0] == null) {
      anchoredIndex = 1;
    } else {
      return null;
    }
    final farBox = anchors[1 - anchoredIndex];
    if (farBox == null) return null;
    final walked = walkOneAnchoredRoute(
      route,
      anchor: fallback[anchoredIndex]!.candidates.first,
      anchoredIndex: anchoredIndex,
      farBox: farBox,
    );
    return walked == null
        ? null
        : (
            points: walked.points,
            fidelity: WireRouteFidelity.walked,
            closingStep: walked.closingStep,
            headSlack: walked.headSlack,
          );
  }

  bool _exactAttach(int oid) {
    final terminal = endpointTerminal(oid);
    if (terminal == null) return endpointConstantBounds(oid) == null;
    final parentOid = terminal.parentOid;
    final parent = parentOid == null ? null : byId[parentOid];
    final frame = parent == null ? null : boundedOwnerOf(parent);
    return frame != null && frame.category == BdObjectKind.structure;
  }

  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _shippableRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (attachPoints.length < 3) return null;
    if (attachPoints[0] == null) {
      return _reverseSolvedRouteTree(route, attachPoints, altAttachPoints, stripTargets, headBox);
    }
    for (final origin in [attachPoints[0], altAttachPoints[0]]) {
      if (origin == null) continue;
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var fullyAnchored = true;
      var contradiction = false;
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) {
          fullyAnchored = false;
          continue;
        }
        ViPoint? match;
        for (final candidate in [stripTargets[i], attachPoints[i], altAttachPoints[i]]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          contradiction = true;
          break;
        }
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      if (contradiction) continue;
      return (tree: tree, fidelity: fullyAnchored ? WireRouteFidelity.closed : WireRouteFidelity.walked);
    }
    return null;
  }

  static ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _reverseSolvedRouteTree(
    ViWireBranchRoute route,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
    HeapRect? headBox,
  ) {
    if (headBox == null) return null;
    final local = walkWireBranchRoute(route, (x: 0, y: 0));
    final leaves = local.leaves;
    if (leaves.length != attachPoints.length - 1) return null;
    List<ViPoint> candidatesOf(int i) => [
      for (final p in [stripTargets[i], attachPoints[i], altAttachPoints[i]])
        if (p != null) p,
    ];
    bool closesAll(ViPoint origin) {
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        final p = (x: leaf.x + origin.x, y: leaf.y + origin.y);
        remaining.update(p, (c) => c + 1, ifAbsent: () => 1);
      }
      for (var i = 1; i < attachPoints.length; i++) {
        if (attachPoints[i] == null) continue;
        ViPoint? match;
        for (final candidate in candidatesOf(i)) {
          if (remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) return false;
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      return true;
    }

    int? seed;
    for (var i = 1; i < attachPoints.length; i++) {
      if (attachPoints[i] != null) {
        seed = i;
        break;
      }
    }
    if (seed == null) return null;
    final candidates = <ViPoint>{
      for (final leaf in leaves)
        for (final p in candidatesOf(seed)) (x: p.x - leaf.x, y: p.y - leaf.y),
    };
    ViPoint? solved;
    for (final origin in candidates) {
      if (origin.x < headBox.left ||
          origin.x >= headBox.right ||
          origin.y < headBox.top ||
          origin.y >= headBox.bottom) {
        continue;
      }
      if (!closesAll(origin)) continue;
      if (solved != null) return null;
      solved = origin;
    }
    if (solved == null) return null;
    return (tree: walkWireBranchRoute(route, solved), fidelity: WireRouteFidelity.walked);
  }

  ({ViWireRouteTree tree, WireRouteFidelity fidelity})? _dcoChildRouteTree(
    ViWireBranchRoute route,
    List<int> refs,
    List<ViPoint?> attachPoints,
    List<ViPoint?> altAttachPoints,
    List<ViPoint?> stripTargets,
  ) {
    if (attachPoints.length < 3 || attachPoints[0] != null) return null;
    final origins = dcoChildTerminalAttach(refs[0])?.candidates;
    if (origins == null) return null;
    for (final origin in origins) {
      final tree = walkWireBranchRoute(route, origin);
      final leaves = tree.leaves;
      if (leaves.length != attachPoints.length - 1) continue;
      final remaining = <ViPoint, int>{};
      for (final leaf in leaves) {
        remaining.update(leaf, (c) => c + 1, ifAbsent: () => 1);
      }
      var closed = true;
      for (var i = 1; i < attachPoints.length; i++) {
        ViPoint? match;
        for (final candidate in [
          stripTargets[i],
          attachPoints[i],
          altAttachPoints[i],
          ...?dcoChildTerminalAttach(refs[i])?.candidates,
        ]) {
          if (candidate != null && remaining.containsKey(candidate)) {
            match = candidate;
            break;
          }
        }
        if (match == null) {
          closed = false;
          break;
        }
        if (remaining.update(match, (count) => count - 1) == 0) remaining.remove(match);
      }
      if (closed) return (tree: tree, fidelity: WireRouteFidelity.closed);
    }
    return null;
  }

  /// The terminal each endpoint belongs to; an endpoint claimed by two terminals has no entry.
  late final Map<int, int> _terminalOidByMemberOid = _buildTerminalIndex();

  Map<int, int> _buildTerminalIndex() {
    final index = <int, int>{};
    final ambiguous = <int>{};
    for (final object in objects) {
      if (object.termBounds == null) continue;
      for (final target in object.refs) {
        _claim(index, ambiguous, target, object.oid);
      }
    }
    return index;
  }

  static void _claim(Map<int, int> index, Set<int> ambiguous, int key, int owner) {
    if (ambiguous.contains(key)) return;
    final prev = index[key];
    if (prev == null) {
      index[key] = owner;
    } else if (prev != owner) {
      index.remove(key);
      ambiguous.add(key);
    }
  }

  /// The terminal object whose `childRef` names the endpoint [oid]; null for an object that is
  /// not an endpoint or is claimed by two terminals.
  BdObject? endpointTerminal(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || !kSignalEndpointDcoKinds.contains(endpoint.kind)) return null;
    final terminalOid = _terminalOidByMemberOid[oid];
    return terminalOid == null ? null : byId[terminalOid];
  }

  /// The endpoint that names each terminal as its DCO; a terminal named by two has no entry.
  late final Map<int, int> _dcoOidByTerminalOid = _buildTerminalDcoIndex();

  Map<int, int> _buildTerminalDcoIndex() {
    final index = <int, int>{};
    final ambiguous = <int>{};
    for (final terminal in objects) {
      if (terminal.termBounds == null) continue;
      for (final target in terminal.refs) {
        final candidate = byId[target];
        if (candidate == null || !kSignalEndpointDcoKinds.contains(candidate.kind)) continue;
        if (!(candidate.refsOf(HeapRefKind.dcoRef) ?? const <int>[]).contains(terminal.oid)) continue;
        _claim(index, ambiguous, terminal.oid, candidate.oid);
      }
    }
    return index;
  }

  /// The endpoint DCO the terminal [oid] refers back to through `dcoRef`.
  BdObject? terminalDco(int oid) {
    final dcoOid = _dcoOidByTerminalOid[oid];
    return dcoOid == null ? null : byId[dcoOid];
  }

  /// Whether the terminal's DCO carries [ViObjFlag.terminalGlyphHidden].
  bool terminalGlyphHidden(int oid) => terminalDco(oid)?.hasFlag(ViObjFlag.terminalGlyphHidden) ?? false;

  /// The constant DCO under the node endpoint [oid], when the endpoint feeds a constant.
  BdObject? endpointConstant(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind) return null;
    for (final child in children(oid)) {
      if (child.objectClass == BdObjectClass.constant) return child;
    }
    return null;
  }

  /// The bounds of the constant's first bounded child; null before LabVIEW 8.6.
  HeapRect? endpointConstantBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in children(constant.oid)) {
      if (child.absBounds != null) return child.absBounds;
    }
    return null;
  }

  /// For a constant drawn as a container, the bounds of its rightmost element part.
  HeapRect? endpointConstantElementBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in children(constant.oid)) {
      if (child.absBounds == null) continue;
      if (child.objectClass != BdObjectClass.array) return null;
      HeapRect? element;
      for (final kid in children(child.oid)) {
        final kidBounds = kid.absBounds;
        if (kid.objectClass == BdObjectClass.chrome ||
            kid.objectClass == BdObjectClass.textLabel ||
            kidBounds == null) {
          continue;
        }
        if (element == null || kidBounds.left > element.left) {
          element = kidBounds;
        }
      }
      return element;
    }
    return null;
  }

  /// The endpoint's terminal box in diagram pixels: its `termBounds` shifted by the nearest
  /// bounded ancestor's origin; null before LabVIEW 8.6.
  HeapRect? endpointTerminalBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final terminal = endpointTerminal(oid);
    final rel = terminal?.termBounds;
    if (terminal == null || rel == null) return null;
    final parentOid = terminal.parentOid;
    final frame = parentOid == null ? null : _boundedOwnerBounds(parentOid);
    if (frame == null) return null;
    return HeapRect(
      top: frame.top + rel.top,
      left: frame.left + rel.left,
      bottom: frame.top + rel.bottom,
      right: frame.left + rel.right,
    );
  }

  /// For a node endpoint without bounds whose single child carries `termBounds`: the centre of
  /// that box, and whether the child is a wide terminal strip.
  ({List<ViPoint> candidates, bool wideRow})? dcoChildTerminalAttach(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind || endpoint.absBounds != null) return null;
    BdObject? part;
    for (final child in children(oid)) {
      if (child.termBounds == null) continue;
      if (part != null) return null;
      part = child;
    }
    final rel = part?.termBounds;
    if (part == null || rel == null) return null;
    final frame = _boundedOwnerBounds(oid);
    if (frame == null) return null;
    final left = frame.left + rel.left, top = frame.top + rel.top;
    final width = rel.right - rel.left, height = rel.bottom - rel.top;
    final centre = (x: left + width ~/ 2, y: top + height ~/ 2);
    return (
      candidates: [centre],
      wideRow: part.objectClass == BdObjectClass.byNameTerminal && width > height,
    );
  }

  /// The centre of the endpoint's terminal or constant box, shifted inward for shift registers.
  ViPoint? wireAttachPoint(int oid) =>
      _attachPointFrom(endpointTerminalBounds(oid) ?? endpointConstantBounds(oid), oid);

  ViPoint? _attachPointFrom(HeapRect? attachRect, int oid) {
    var rect = attachRect;
    if (rect == null) {
      if (_predatesFrameRelativeTerms) return null;
      final endpoint = byId[oid];
      if (endpoint == null || endpoint.objectClass != BdObjectClass.panelTerminal) return null;
      rect = endpoint.absBounds;
      if (rect == null) return null;
    }
    var x = rect.left + (rect.right - rect.left) ~/ 2;
    if (attachRect != null) {
      final terminalClass = endpointTerminal(oid)?.objectClass;
      if (terminalClass == BdObjectClass.rightShiftRegister) {
        x -= kShiftRegisterColumnLeftOffset;
      } else if (terminalClass == BdObjectClass.leftShiftRegister) {
        x += kShiftRegisterColumnRightOffset;
      }
    }
    return (x: x, y: rect.top + (rect.bottom - rect.top) ~/ 2);
  }

  ViPoint? _stripFarTarget(int oid, HeapRect? attachRect, ViPoint? attach) {
    if (attachRect == null || attach == null) return null;
    if (attachRect.right - attachRect.left != kTerminalStripColumnWidth) return null;
    if (!kBdTerminalStripClasses.contains(endpointTerminal(oid)?.objectClass)) return null;
    return (x: attach.x - kTerminalStripTargetLeftOffset, y: attach.y);
  }

  static List<ViPoint>? _closedRoutePoints(ViWireRoute route, ViPoint? start, ViPoint? destination) {
    if (start == null || destination == null) return null;
    if (route.pointCount == 1) return start == destination ? [start] : null;
    final walk = walkRouteBends(route, origin: start);
    if (walk == null) return null;
    final points = walk.points;
    final tail = points.last;
    if (walk.closingHorizontal ? tail.y != destination.y : tail.x != destination.x) return null;
    final along = walk.closingHorizontal ? destination.x - tail.x : destination.y - tail.y;
    if (along != 0 && (along > 0 ? 1 : -1) != walk.closingSign) return null;
    if (along != 0) points.add(destination);
    return points;
  }

  HeapRect? _boundedOwnerBounds(int oid) {
    final start = byId[oid];
    return start == null ? null : boundedOwnerOf(start)?.absBounds;
  }
}
