/// The object tree of one block-diagram heap: [BdDiagram] indexes the objects by oid, parent
/// and shape, and derives one [ViWire] per [BdSignal], with its endpoints, anchors and decoded
/// route.
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

/// The objects of one `BDHb` section, indexed by oid, parent and shape, with the wires derived
/// from its signals.
class BdDiagram extends HeapObjectTree<BdObject> {
  BdDiagram({required super.objects, super.version, super.sectionIndex}) {
    for (final object in objects) {
      switch (object) {
        case BdPlaced():
          placed.add(object);
          switch (object) {
            case BdNode():
              nodes.add(object);
            case BdStructure():
              structures.add(object);
            case BdPanelTerminal():
              panelTerminals.add(object);
            case BdText():
              textLabels.add(object);
            case BdControlBody():
              controlBodies.add(object);
            case BdContainer() || BdPane() || BdWire() || BdPart() || BdUnknownPlaced():
              break;
          }
        case BdSignal():
          signals.add(object);
        case BdTerminal():
          terminals.add(object);
        case BdConstant():
          constants.add(object);
        case BdRoot() || BdFrame() || BdTerminalHolder() || BdTunnelIndexer() || BdUnplaced():
          break;
      }
    }
  }

  /// Every object with bounds, in heap order.
  final List<BdPlaced> placed = [];

  final List<BdNode> nodes = [];

  final List<BdStructure> structures = [];

  final List<BdSignal> signals = [];

  final List<BdTerminal> terminals = [];

  final List<BdPanelTerminal> panelTerminals = [];

  final List<BdConstant> constants = [];

  final List<BdText> textLabels = [];

  final List<BdControlBody> controlBodies = [];

  late final bool _predatesFrameRelativeTerms = _predatesFrameRelativeTermBounds(version);

  /// The frame objects of a structure, in heap order.
  List<BdFrame> framesOf(BdStructure structure) => [
    for (final child in childrenOf(structure))
      if (child is BdFrame) child,
  ];

  /// The frame a multi-frame structure shows, null for an index past its frames.
  int? displayedFrameIndex(BdMultiFrameStructure structure) {
    final index = structure.visibleFrameIndex;
    return index < framesOf(structure).length ? index : null;
  }

  /// One wire per signal.
  late final List<ViWire> wires = [for (final signal in signals) _buildWire(signal)];

  ViWire _buildWire(BdSignal signal) {
    final refs = signal.endpoints;
    final raw = signal.wireTableRaw;
    final route = raw == null ? null : decodeWireRoute(raw);
    final branchRoute = raw == null || refs.length < 3 ? null : decodeWireBranchRoute(raw);
    final constantBounds = [for (final oid in refs) endpointConstantBounds(oid)];
    final attachRects = [for (var i = 0; i < refs.length; i++) endpointTerminalBounds(refs[i]) ?? constantBounds[i]];
    final attachPoints = [for (var i = 0; i < refs.length; i++) _attachPointFrom(attachRects[i], refs[i])];
    final altAttachPoints = [
      for (var i = 0; i < refs.length; i++)
        switch (endpointConstantElementBounds(refs[i])) {
          null => null,
          final elem => attachPoints[i] == null ? null : _attachPointFrom(elem, refs[i]),
        },
    ];
    final stripTargets = [
      for (var i = 0; i < refs.length; i++) _stripFarTarget(refs[i], attachRects[i], attachPoints[i]),
    ];
    final anchors = [for (var i = 0; i < refs.length; i++) constantBounds[i] ?? _boundedOwnerBounds(refs[i])];
    final signalKind = signal.lastSignalKind;
    final points = route == null || refs.length != 2
        ? null
        : _routePointsFor(route, refs, attachPoints, anchors, altAttachPoints, stripTargets);
    return ViWire(
      signalOid: signal.oid,
      endpointOids: List<int>.of(refs),
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
                _dcoChildRouteTree(branchRoute, refs, attachPoints, altAttachPoints, stripTargets),
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
        final walked = walkOneAnchoredRoute(route, anchor: anchorPoint, anchoredIndex: anchoredIndex, farBox: farBox);
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
    final parent = parentOf(terminal);
    final frame = parent == null ? null : boundedOwnerOf(parent) as BdObject?;
    return frame?.category == BdObjectKind.structure;
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

  /// The terminal each endpoint belongs to, and the endpoint that names each terminal as its
  /// DCO; a key claimed by two owners has no entry.
  late final ({Map<int, BdTerminal> terminalByEndpoint, Map<int, BdObject> dcoByTerminal}) _terminalIndex =
      _buildTerminalIndex();

  ({Map<int, BdTerminal> terminalByEndpoint, Map<int, BdObject> dcoByTerminal}) _buildTerminalIndex() {
    final terminalByEndpoint = <int, BdTerminal>{}, dcoByTerminal = <int, BdObject>{};
    final ambiguousEndpoints = <int>{}, ambiguousTerminals = <int>{};
    for (final terminal in terminals) {
      for (final target in terminal.refs) {
        _claim(terminalByEndpoint, ambiguousEndpoints, target, terminal);
        final candidate = byOid(target);
        final dcoRef = switch (candidate) {
          BdTerminalHolder(:final dcoRef) => dcoRef,
          BdPanelTerminal(:final dcoRef) => dcoRef,
          _ => null,
        };
        if (candidate == null || dcoRef != terminal.oid) continue;
        _claim(dcoByTerminal, ambiguousTerminals, terminal.oid, candidate);
      }
    }
    return (terminalByEndpoint: terminalByEndpoint, dcoByTerminal: dcoByTerminal);
  }

  static void _claim<V>(Map<int, V> index, Set<int> ambiguous, int key, V owner) {
    if (ambiguous.contains(key)) return;
    final prev = index[key];
    if (prev == null) {
      index[key] = owner;
    } else if (!identical(prev, owner)) {
      index.remove(key);
      ambiguous.add(key);
    }
  }

  /// Whether the object with [oid] is a signal endpoint: a terminal holder or a panel terminal.
  bool isSignalEndpoint(int oid) => switch (byOid(oid)) {
    BdTerminalHolder() || BdPanelTerminal() => true,
    _ => false,
  };

  /// The terminal whose `childRef` names the endpoint [oid]; null for an object that is not an
  /// endpoint or is claimed by two terminals.
  BdTerminal? endpointTerminal(int oid) => isSignalEndpoint(oid) ? _terminalIndex.terminalByEndpoint[oid] : null;

  /// The endpoint DCO the terminal [oid] refers back to through `dcoRef`.
  BdObject? terminalDco(int oid) => _terminalIndex.dcoByTerminal[oid];

  /// Whether the terminal's DCO carries [ViObjFlag.terminalGlyphHidden].
  bool terminalGlyphHidden(int oid) => terminalDco(oid)?.hasFlag(ViObjFlag.terminalGlyphHidden) ?? false;

  /// The constant under the terminal holder [oid], when the endpoint feeds a constant.
  BdConstant? endpointConstant(int oid) {
    final endpoint = byOid(oid);
    if (endpoint is! BdTerminalHolder) return null;
    for (final child in childrenOf(endpoint)) {
      if (child is BdConstant) return child;
    }
    return null;
  }

  /// The bounds of the constant's first placed child; null before LabVIEW 8.6.
  HeapRect? endpointConstantBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenOf(constant)) {
      if (child is BdPlaced) return child.absBounds;
    }
    return null;
  }

  /// For a constant drawn as a container, the bounds of its rightmost element part.
  HeapRect? endpointConstantElementBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenOf(constant)) {
      if (child is! BdPlaced) continue;
      if (child.objectClass != BdObjectClass.array) return null;
      HeapRect? element;
      for (final kid in childrenOf(child)) {
        if (kid is! BdPlaced || kid.objectClass == BdObjectClass.chrome || kid is BdText) continue;
        if (element == null || kid.absBounds.left > element.left) element = kid.absBounds;
      }
      return element;
    }
    return null;
  }

  /// The endpoint's terminal box in diagram pixels: its `termBounds` shifted by the nearest
  /// placed ancestor's origin; null before LabVIEW 8.6.
  HeapRect? endpointTerminalBounds(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final terminal = endpointTerminal(oid);
    if (terminal == null) return null;
    final parent = parentOf(terminal);
    final frame = parent == null ? null : boundedOwnerOf(parent)?.absBounds;
    return frame == null ? null : terminal.termBounds.shift(frame.top, frame.left);
  }

  /// For a terminal holder whose single child is a terminal: the centre of that terminal's box,
  /// and whether the terminal is a wide terminal strip.
  ({List<ViPoint> candidates, bool wideRow})? dcoChildTerminalAttach(int oid) {
    if (_predatesFrameRelativeTerms) return null;
    final endpoint = byOid(oid);
    if (endpoint is! BdTerminalHolder) return null;
    BdTerminal? part;
    for (final child in childrenOf(endpoint)) {
      if (child is! BdTerminal) continue;
      if (part != null) return null;
      part = child;
    }
    if (part == null) return null;
    final frame = boundedOwnerOf(endpoint)?.absBounds;
    if (frame == null) return null;
    final rel = part.termBounds;
    final left = frame.left + rel.left, top = frame.top + rel.top;
    final width = rel.right - rel.left, height = rel.bottom - rel.top;
    final centre = (x: left + width ~/ 2, y: top + height ~/ 2);
    return (candidates: [centre], wideRow: part.objectClass == BdObjectClass.byNameTerminal && width > height);
  }

  /// The centre of the endpoint's terminal or constant box, shifted inward for shift registers.
  ViPoint? wireAttachPoint(int oid) =>
      _attachPointFrom(endpointTerminalBounds(oid) ?? endpointConstantBounds(oid), oid);

  ViPoint? _attachPointFrom(HeapRect? attachRect, int oid) {
    var rect = attachRect;
    if (rect == null) {
      if (_predatesFrameRelativeTerms) return null;
      final endpoint = byOid(oid);
      if (endpoint is! BdPanelTerminal) return null;
      rect = endpoint.absBounds;
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
    final start = byOid(oid);
    return start == null ? null : boundedOwnerOf(start)?.absBounds;
  }
}
