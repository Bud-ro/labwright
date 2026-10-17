/// The object tree of one C4 record heap: [buildDiagram] replays an `FPHb` or `BDHb` body
/// through [walkHeapObjects] and turns every object header into a [ViHeapObject], every
/// record it carries into a field of that object, and every `signal` object into a [ViWire]
/// with its decoded route.
///
/// Which records feed which fields:
///
/// ```text
/// record                                   field
/// object header                            oid, kind, objectClass, offset, parentOid
/// C4 bounds (0x2d)                         bounds; absBounds accumulates the ancestors' origins
/// C4 size (0x1f)                           termCount, one per record
/// C4 caption (0x22), attribute shortText   label
/// C4 formatString (0x74)                   typeKind (format conversion character)
/// C4 stringTable (0x2e)                    items
/// C4 description (0x19)                    helpText
/// C4 plotName (0x27)                       plotNames
/// C4 path (0xa4), symbolName (0xc4)        foreignLibraryPath, foreignEntryPoint (Call Library nodes)
/// reference records                        refs (childRef targets), refsOf (every kind)
/// attributes                               controlMin/Max, constText, constValueRaw, displayFormat,
///                                          labelModeWord, termBounds, termBmp, typeDescIdx, objFlags,
///                                          primResId, dIdx, wireTableRaw, defaultFrameIndex,
///                                          lastSignalKind, the *Rgb colours, plotColors
/// font run groups                          textStyleRuns
/// array index group                        arrayIndex
/// case selector groups                     selectorRanges, selectorStrings
/// ```
///
/// [resolveDataSpaceTypes] then joins the diagrams to the type pool through the data-space type
/// map (`TM80`), filling `dataType`, `resolvedType` and the member lists, and
/// [decodeBdConstValues] reads each constant's flat value through its type.
///
/// [ViDiagram] indexes the objects by oid and parent and derives the wires; [ViWire] carries a
/// wire's endpoints, anchors and route; [ViWireRoute], [ViWireBranchRoute] and
/// [ViWireRouteTree] are the decoded route tables; [ViSignalType] is a wire's type word;
/// [BdHeapObjectClass] and [FpHeapObjectClass] name the object classes.
library;

import 'dart:math';
import 'dart:typed_data';

import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import 'obj_flags.dart';
import 'objects.dart';
import 'wire_route.dart';

int _signedAtWidth(int value, HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.u8 => value.toSigned(8),
  HeapAttrWidth.u16 => value.toSigned(16),
  HeapAttrWidth.u24 => value.toSigned(24),
  HeapAttrWidth.rgb => value.toSigned(32),
  _ => value,
};

String? _selectorPoolString(Uint8List body, int offset, int lead, int span) {
  if (lead == kHeapRecordPrefix) {
    if (offset + 3 > body.length) return null;
    final count = body[offset + 2];
    if (3 + count > span || offset + 3 + count > body.length) return null;
    return String.fromCharCodes(body.sublist(offset + 3, offset + 3 + count));
  }
  final attr = decodeHeapAttr(body, offset);
  final value = attr?.asInt;
  if (attr == null || value == null) return null;
  final bytes = switch (attr.width) {
    HeapAttrWidth.u8 => 1,
    HeapAttrWidth.u16 => 2,
    HeapAttrWidth.u24 => 3,
    HeapAttrWidth.rgb => 4,
    _ => 0,
  };
  final chars = [for (var i = bytes - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

const int _structureAreaCap = 20000;

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

/// Every object of a diagram by oid; the last declaration wins when a heap repeats one.
class ViObjectsByOid {
  ViObjectsByOid(this._objects) : _slotByOid = Int32List(_oidCount(_objects)) {
    for (var i = 0; i < _objects.length; i++) {
      _slotByOid[_objects[i].oid] = i + 1;
    }
  }

  static int _oidCount(List<ViHeapObject> objects) {
    var top = -1;
    for (final object in objects) {
      if (object.oid > top) top = object.oid;
    }
    return top + 1;
  }

  final List<ViHeapObject> _objects;

  /// One past the object's position in [_objects]; zero where no object has the oid.
  final Int32List _slotByOid;

  ViHeapObject? operator [](int? oid) {
    if (oid == null || oid < 0 || oid >= _slotByOid.length) return null;
    final slot = _slotByOid[oid];
    return slot == 0 ? null : _objects[slot - 1];
  }
}

/// The objects of one heap section, indexed by oid and parent, with the wires derived from
/// its signals.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects, this.version, this.sectionIndex = 0})
    : byId = ViObjectsByOid(objects),
      _childrenOf = List<List<ViHeapObject>?>.filled(objects.length, null) {
    for (var i = 0; i < objects.length; i++) {
      objects[i].index = i;
    }
    for (final object in objects) {
      final parent = parentOf(object);
      if (parent != null) (_childrenOf[parent.index] ??= <ViHeapObject>[]).add(object);
    }
  }

  /// The section the heap came from, `FPHb` or `BDHb`, and its index among that block's sections.
  final String sectionTag;

  final int sectionIndex;

  /// The saving LabVIEW version as `major.minor`, when the caller knows it.
  final String? version;

  /// Every object in heap order.
  final List<ViHeapObject> objects;

  final ViObjectsByOid byId;

  final List<List<ViHeapObject>?> _childrenOf;

  late final bool _predatesFrameRelativeTerms = _predatesFrameRelativeTermBounds(version);

  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  /// The object [object]'s [ViHeapObject.parentOid] names, null for a root.
  ViHeapObject? parentOf(ViHeapObject object) {
    final parentOid = object.parentOid;
    return parentOid == null ? null : byId[parentOid];
  }

  /// The objects whose [ViHeapObject.parentOid] is [object]'s oid, in heap order.
  List<ViHeapObject> childrenOf(ViHeapObject object) => _childrenOf[object.index] ?? const <ViHeapObject>[];

  List<ViHeapObject> children(int oid) {
    final object = byId[oid];
    return object == null ? const <ViHeapObject>[] : childrenOf(object);
  }

  /// The frame objects of a structure, in heap order.
  List<ViHeapObject> framesOf(ViHeapObject structure) => [
    for (final child in children(structure.oid))
      if (child.objectClass == BdHeapObjectClass.frame) child,
  ];

  /// The frame a multi-frame structure shows, null for other objects or an index past its frames.
  int? displayedFrameIndex(ViHeapObject structure) {
    if (!structure.objectClass.isMultiFrameStructure) return null;
    var frames = 0;
    for (final child in children(structure.oid)) {
      if (child.objectClass == BdHeapObjectClass.frame) frames++;
    }
    final index = structure.visibleFrameIndex;
    return index < frames ? index : null;
  }

  /// Every object with a bounds record.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);

  /// One wire per `signal` object.
  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.objectClass == BdHeapObjectClass.signal) _buildWire(object),
  ];

  ViWire _buildWire(ViHeapObject object) {
    final raw = object.wireTableRaw;
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
    final signalKind = object.lastSignalKind;
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
    final frame = parent == null ? null : _boundedOwnerObject(parent);
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
  ViHeapObject? endpointTerminal(int oid) {
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
  ViHeapObject? terminalDco(int oid) {
    final dcoOid = _dcoOidByTerminalOid[oid];
    return dcoOid == null ? null : byId[dcoOid];
  }

  /// Whether the terminal's DCO carries [ViObjFlag.terminalGlyphHidden].
  bool terminalGlyphHidden(int oid) => terminalDco(oid)?.hasFlag(ViObjFlag.terminalGlyphHidden) ?? false;

  /// The constant DCO under the node endpoint [oid], when the endpoint feeds a constant.
  ViHeapObject? endpointConstant(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind) return null;
    for (final child in children(oid)) {
      if (child.objectClass == BdHeapObjectClass.constant) return child;
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
      if (child.objectClass != BdHeapObjectClass.array) return null;
      HeapRect? element;
      for (final kid in children(child.oid)) {
        final kidBounds = kid.absBounds;
        if (kid.objectClass == BdHeapObjectClass.chrome ||
            kid.objectClass == BdHeapObjectClass.textLabel ||
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
    ViHeapObject? part;
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
      wideRow: part.kind == 0x62 && width > height,
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
      if (endpoint == null || endpoint.objectClass != BdHeapObjectClass.panelTerminal) return null;
      rect = endpoint.absBounds;
      if (rect == null) return null;
    }
    var x = rect.left + (rect.right - rect.left) ~/ 2;
    if (attachRect != null) {
      final terminalKind = endpointTerminal(oid)?.kind;
      if (terminalKind == BdHeapObjectClass.rightShiftRegister.code) {
        x -= kShiftRegisterColumnLeftOffset;
      } else if (terminalKind == BdHeapObjectClass.leftShiftRegister.code) {
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
    return start == null ? null : _boundedOwnerObject(start)?.absBounds;
  }

  ViHeapObject? _boundedOwnerObject(ViHeapObject start) {
    ViHeapObject? object = start;
    for (var depth = 0; object != null && depth < objects.length; depth++) {
      if (object.absBounds != null) return object;
      final parentOid = object.parentOid;
      object = parentOid == null ? null : byId[parentOid];
    }
    return null;
  }
}

int? _attrScalarBytes(HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.flag => 0,
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => null,
};

Uint8List? _attrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = _attrScalarBytes(record.width);
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  final out = Uint8List(scalarBytes);
  for (var i = 0; i < scalarBytes; i++) {
    out[i] = (value >> (8 * (scalarBytes - 1 - i))) & 0xff;
  }
  return out;
}

const int _intCertainCeil = 0x800000;

const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

const Set<int> _zeroPayloadLengths = {5, 9};

// TODO: absolute (type 0) and UNC (type 2) path text is not decoded.
/// The segments of a flat relative `PTH0` path joined with backslashes; null for any other
/// path form.
String? decodeFlatPathText(Uint8List? raw) {
  if (raw == null || raw.length < 12) return null;
  if (raw[0] != 0x50 || raw[1] != 0x54 || raw[2] != 0x48 || raw[3] != 0x30) {
    return null;
  }
  final view = ByteData.sublistView(raw);
  final contentLength = view.getUint32(4);
  final end = 8 + contentLength;
  if (end > raw.length) return null;
  final pathType = view.getUint16(8);
  final count = view.getUint16(10);
  if (pathType != 1 || count < 1) return null;
  var offset = 12;
  final segments = <String>[];
  for (var i = 0; i < count; i++) {
    if (offset >= end) return null;
    final len = raw[offset];
    if (offset + 1 + len > end) return null;
    segments.add(String.fromCharCodes(raw, offset + 1, offset + 1 + len));
    offset += 1 + len;
  }
  if (offset != end) return null;
  return segments.join(r'\');
}

/// A constant's value read from its flat bytes by the class of the control that draws it:
/// a path, a four-character string, a boolean, or a small non-negative integer, a zero or a
/// double in a plausible range; null when the bytes do not fit the carrier.
Object? decodeBdConstantValue({
  required HeapObjectClass carrier,
  required Uint8List? flat,
  required bool scalar,
  bool hasEnumItems = false,
}) {
  if (flat == null) return null;
  final scalarBytes = scalar ? flat.length : null;
  int? scalarValue;
  if (scalar) {
    var magnitude = 0;
    for (final byte in flat) {
      magnitude = (magnitude << 8) | byte;
    }
    scalarValue = magnitude;
  }
  final raw = scalar ? null : flat;
  switch (carrier) {
    case BdHeapObjectClass.path:
      return decodeFlatPathText(raw);
    case BdHeapObjectClass.string:
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((b) => b >= 0x20 && b < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case BdHeapObjectClass.boolean:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case BdHeapObjectClass.enumRing when hasEnumItems:
    case BdHeapObjectClass.typeDefinition when hasEnumItems:
    case BdHeapObjectClass.numeric:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != BdHeapObjectClass.numeric || raw == null) return null;
      if (_zeroPayloadLengths.contains(raw.length) && raw.every((byte) => byte == 0)) {
        return 0;
      }
      if (raw.length == 8) {
        final f64Reading = ByteData.sublistView(raw).getFloat64(0);
        if (!f64Reading.isFinite) return null;
        if (f64Reading == 0 || (f64Reading.abs() >= _dblWindowFloor && f64Reading.abs() <= _dblWindowCeil)) {
          return f64Reading;
        }
      }
      return null;
    default:
      return null;
  }
}

/// Builds the object tree of a heap body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, flat-sequence frames are shifted
/// to their declared offsets, items and help text bubble up to the owning control, unlabelled
/// nodes take their first child label, and controls under a scrolled viewport are re-anchored.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb', String? version, int sectionIndex = 0}) {
  final objects = <ViHeapObject>[];
  final length = body.length;
  final objectCapacity = length ~/ kHeapObjectHeaderMinLength + 1;
  final typeKindEvidence = Int32List(objectCapacity);
  final originTop = Int32List(objectCapacity);
  final originLeft = Int32List(objectCapacity);
  final view = ByteData.sublistView(body);

  ViHeapObject? styleRunOwner;
  var styleRunGroupDepth = 0;
  var styleRunStart = 0;
  var styleRunFontId = 0;
  var styleRunOpen = false;
  var styleRuns = <({int start, int fontId})>[];

  ViHeapObject? arrayIndexOwner;
  var arrayIndexGroupDepth = 0;

  ViHeapObject? selectorOwner;
  var selectorGroupDepth = 0;
  var selectorInPool = false;
  var selectorEntryOpen = false;
  var selectorRanges = <ViSelectorRange>[];
  var selectorStrings = <String>[];
  var entryLow = 0, entryHigh = 0, entryLowBound = 0, entryHighBound = 0, entryFrame = 0;

  final scopes = <ViHeapObject?>[];
  final groupTags = <int?>[];
  var next = 4;
  while (next < length) {
    final offset = next;
    final step = recordSkip(body, offset);
    if (step == null || offset + step > length) break;
    next = offset + step;
    final recordLength = step;
    final lead = body[offset];
    final cur = scopes.isEmpty ? null : scopes.last;
    final headerLength = isHeapObjectHeaderLead(lead) ? heapObjectHeaderLength(body, offset) : 0;
    if (headerLength != 0) {
      final kind = heapObjectHeaderKind(body, offset);
      final oid = heapObjectHeaderOid(body, offset, headerLength);
      final index = objects.length;
      final object = ViHeapObject(
        oid: oid,
        kind: kind,
        offset: offset,
        objectClass: heapObjectClassOf(sectionTag, kind),
      )..index = index;
      object.parentOid = cur?.oid;
      originTop[index] = cur == null ? 0 : originTop[cur.index];
      originLeft[index] = cur == null ? 0 : originLeft[cur.index];
      objects.add(object);
      scopes.add(object);
      groupTags.add(null);
      continue;
    }
    if (isHeapGroupOpenLead(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      final groupTag = body[offset + 1];
      scopes.add(cur);
      groupTags.add(groupTag);
      if (selectorOwner != null) {
        selectorGroupDepth++;
        if (groupTag == HeapGroupTag.selectorRange.tag && selectorGroupDepth == 2 && !selectorInPool) {
          selectorEntryOpen = true;
          entryLow = entryHigh = entryLowBound = entryHighBound = entryFrame = 0;
        }
      } else if (cur != null && cur.objectClass == BdHeapObjectClass.caseStructure) {
        if (kViSelectorGroupTags.contains(groupTag)) {
          selectorOwner = cur;
          selectorGroupDepth = 1;
          selectorInPool = groupTag == HeapGroupTag.selectorStringPool.tag;
          if (selectorInPool) {
            selectorStrings = <String>[];
          } else {
            selectorRanges = <ViSelectorRange>[];
          }
        }
      }
      if (arrayIndexOwner != null) {
        arrayIndexGroupDepth++;
      } else if (groupTag == HeapGroupTag.arrayIndex.tag && cur != null && cur.objectClass.isArray) {
        arrayIndexOwner = cur;
        arrayIndexGroupDepth = 1;
      }
      if (styleRunOwner == null) {
        if (groupTag == HeapGroupTag.fontRunList.tag && cur != null) {
          styleRunOwner = cur;
          styleRunGroupDepth = 1;
          styleRuns = [];
        }
        continue;
      }
      styleRunGroupDepth++;
      if (groupTag == HeapGroupTag.fontRun.tag && styleRunGroupDepth == 2) {
        styleRunOpen = true;
        styleRunStart = 0;
        styleRunFontId = 0;
      }
      continue;
    }
    if (isHeapGroupCloseLead(lead)) {
      if (scopes.isEmpty) continue;
      final closed = scopes.removeLast();
      final groupTag = groupTags.removeLast();
      if (groupTag == null) {
        closed?.end = next;
        continue;
      }
      final owner = selectorOwner;
      if (owner != null) {
        if (selectorEntryOpen && selectorGroupDepth == 2) {
          selectorRanges.add(
            ViSelectorRange(
              low: entryLow,
              high: entryHigh,
              lowBound: ViSelectorBound.ofCode(entryLowBound),
              highBound: ViSelectorBound.ofCode(entryHighBound),
              frame: entryFrame,
            ),
          );
          selectorEntryOpen = false;
        }
        if (--selectorGroupDepth == 0) {
          if (selectorInPool) {
            if (owner.selectorStrings.isEmpty) owner.selectorStrings = selectorStrings;
          } else if (owner.selectorRanges.isEmpty) {
            owner.selectorRanges = selectorRanges;
          }
          selectorOwner = null;
          selectorInPool = false;
        }
      }
      if (arrayIndexOwner != null && --arrayIndexGroupDepth == 0) {
        arrayIndexOwner = null;
      }
      final runOwner = styleRunOwner;
      if (runOwner == null) continue;
      styleRunGroupDepth--;
      if (styleRunOpen && styleRunGroupDepth == 1) {
        styleRuns.add((start: styleRunStart, fontId: styleRunFontId));
        styleRunOpen = false;
      }
      if (styleRunGroupDepth == 0) {
        if (styleRuns.isNotEmpty && runOwner.textStyleRuns.isEmpty) {
          runOwner.textStyleRuns = styleRuns;
        }
        styleRunOwner = null;
      }
      continue;
    }
    if (cur == null) continue;
    if (selectorOwner != null && identical(cur, selectorOwner)) {
      if (selectorInPool) {
        final value = _selectorPoolString(body, offset, lead, recordLength);
        if (value != null) {
          selectorStrings.add(value);
          continue;
        }
      } else if (selectorEntryOpen) {
        final attr = decodeHeapAttrIn(view, body, offset);
        final value = attr?.asInt;
        if (attr != null && value != null) {
          final tag = attr.rawTag;
          if (tag == SelectorRangeAttr.low.raw) {
            entryLow = _signedAtWidth(value, attr.width);
            continue;
          }
          if (tag == SelectorRangeAttr.high.raw) {
            entryHigh = _signedAtWidth(value, attr.width);
            continue;
          }
          if (tag == SelectorRangeAttr.lowBound.raw) {
            entryLowBound = value;
            continue;
          }
          if (tag == SelectorRangeAttr.highBound.raw) {
            entryHighBound = value;
            continue;
          }
          if (tag == SelectorRangeAttr.frame.raw) {
            entryFrame = value;
            continue;
          }
        }
      }
    }
    final indexOwner = arrayIndexOwner;
    if (indexOwner != null && identical(cur, indexOwner)) {
      final attr = decodeHeapAttrIn(view, body, offset);
      final value = attr?.asInt;
      if (value != null && attr != null && attr.rawTag == HeapAttribute.arrayElemValue.raw) {
        indexOwner.arrayIndex = value;
        continue;
      }
    }
    if (styleRunOpen && identical(cur, styleRunOwner)) {
      final attr = decodeHeapAttrIn(view, body, offset);
      final value = attr?.asInt;
      if (attr != null && value != null) {
        if (attr.rawTag == FontRunAttr.start.raw) {
          styleRunStart = value;
          continue;
        }
        if (attr.rawTag == FontRunAttr.fontId.raw) {
          styleRunFontId = value;
          continue;
        }
      }
    }
    if (lead == kHeapRecordPrefix) {
      final opcode = body[offset + 1];
      final start = offset + (body[offset + 2] == 0xff ? 5 : 3);
      final end = offset + recordLength;
      typeKindEvidence[cur.index] |= ViTypeKindEvidence.ofOpcode(opcode);
      switch (opcode) {
        case 0x2d:
          if (cur.bounds == null && end - start == 8) {
            final bounds = HeapRect(
              top: view.getInt16(start),
              left: view.getInt16(start + 2),
              bottom: view.getInt16(start + 4),
              right: view.getInt16(start + 6),
            );
            cur.bounds = bounds;
            cur.boundsOffset = start;
            final top = originTop[cur.index] + bounds.top;
            final left = originLeft[cur.index] + bounds.left;
            originTop[cur.index] = top;
            originLeft[cur.index] = left;
            cur.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
          }
        case 0x22:
          if (cur.label == null) {
            cur.label = heapRecordText(Uint8List.sublistView(body, start, end));
            if (cur.label != null) {
              cur.labelOffset = offset;
              cur.labelLength = recordLength;
            }
          }
        case 0x1f:
          cur.termCount++;
        case 0x74:
          if (typeKindEvidence[cur.index] & ViTypeKindEvidence.numeric.bit == 0) {
            typeKindEvidence[cur.index] |= ViTypeKindEvidence.ofFormat(Uint8List.sublistView(body, start, end));
          }
        case 0x2e:
          if (cur.items.isEmpty) cur.items = _parseEnumItems(Uint8List.sublistView(body, start, end));
        case 0x19:
          cur.helpText ??= heapDescriptionText(Uint8List.sublistView(body, start, end));
        case 0x27:
          final text = heapRecordText(Uint8List.sublistView(body, start, end));
          if (text != null && text.isNotEmpty) cur.plotNames = [...cur.plotNames, text];
        case 0xa4:
          if (cur.objectClass == BdHeapObjectClass.callLibrary) {
            cur.foreignLibraryPath ??= heapRecordPath(Uint8List.sublistView(body, start, end));
          }
        case 0xc4:
          if (cur.objectClass == BdHeapObjectClass.callLibrary) {
            cur.foreignEntryPoint ??= heapRecordText(Uint8List.sublistView(body, start, end));
          }
      }
    } else if (lead == 0x14) {
      if (offset + 6 <= length && body[offset + 2] == 0x01 && body[offset + 3] == 0xfd) {
        final wide = (body[offset + 4] & 0x80) != 0;
        if (!wide || offset + 10 <= length) {
          cur.addRef(
            HeapRefKind.fromRaw(heapRawId(lead, body[offset + 1])),
            wide ? view.getUint32(offset + 6) : view.getUint16(offset + 4),
          );
        }
      }
    } else if (offset + 1 < length && _modelAttributeRaws[heapRawId(lead, body[offset + 1])]) {
      final attribute = HeapAttribute.fromRaw(heapRawId(lead, body[offset + 1]));
      final lo = lead & 0xf, hi = lead >> 4;
      final scalarBytes = hi >> 1;
      if ((lo == 4 || lo == 5 || lo == 6) &&
          (hi == 2 || hi == 4 || hi == 6 || hi == 8) &&
          offset + 2 + scalarBytes <= length &&
          attribute != HeapAttribute.shortText &&
          attribute != HeapAttribute.constValue &&
          attribute != HeapAttribute.formatStyle) {
        final value = switch (hi) {
          2 => body[offset + 2],
          4 => view.getUint16(offset + 2),
          6 => (view.getUint16(offset + 2) << 8) | body[offset + 4],
          _ => view.getUint32(offset + 2),
        };
        switch (attribute) {
          case HeapAttribute.typeDescIndex:
            cur.typeDescIdx ??= value;
          case HeapAttribute.objFlags:
            cur.objFlags ??= value;
          case HeapAttribute.termBMPs:
            cur.termBmp ??= value;
          case HeapAttribute.cosmColorB:
            if (cur.objectClass.isLabel) cur.labelModeWord ??= value;
          case HeapAttribute.primResID:
            if (cur.objectClass == BdHeapObjectClass.primitive && hi == 4) cur.primResId ??= value;
          case HeapAttribute.dIdx:
            if (cur.objectClass.isMultiFrameStructure) cur.dIdx ??= value;
          case HeapAttribute.conNum:
            if (cur.objectClass == FpHeapObjectClass.dco) cur.conNum ??= value;
          case HeapAttribute.selectDefaultCase:
            if (cur.objectClass == BdHeapObjectClass.caseStructure && value != kViNoDefaultFrame) {
              cur.defaultFrameIndex ??= value;
            }
          case HeapAttribute.lastSignalKind:
            if (cur.objectClass == BdHeapObjectClass.signal && value <= 0xffff) cur.lastSignalKind ??= value;
          case HeapAttribute.compressedWireTable:
            if (cur.objectClass == BdHeapObjectClass.signal) {
              cur.wireTableRaw ??= body.sublist(offset + 2, offset + 2 + scalarBytes);
            }
          default:
            if (attribute.kind == HeapAttrKind.color) {
              final rgb = value & 0xffffff;
              if (value != 0x1 && !(rgb == 0 && value >>> 24 == 0x01)) {
                switch (attribute) {
                  case HeapAttribute.backgroundColor:
                    cur.bgRgb ??= rgb;
                  case HeapAttribute.fgColor:
                    cur.fgRgb ??= rgb;
                  case HeapAttribute.contentColor:
                    cur.contentRgb ??= rgb;
                  case HeapAttribute.structColor:
                    cur.structRgb ??= rgb;
                  case HeapAttribute.borderColor:
                    cur.borderRgb ??= rgb;
                  case HeapAttribute.plotColor:
                    (cur.plotColors.isEmpty ? (cur.plotColors = <int>[]) : cur.plotColors).add(rgb);
                  default:
                    break;
                }
              }
            }
        }
        continue;
      }
      final attr = decodeHeapAttrIn(view, body, offset);
      if (attr == null) continue;
      final number = attr.asDouble;
      if (number != null && cur.objectClass.isControlTerminal) {
        if (attr.attribute == HeapAttribute.stdNumMin) cur.controlMin ??= number;
        if (attr.attribute == HeapAttribute.stdNumMax) cur.controlMax ??= number;
      }
      if (attr.attribute == HeapAttribute.constValue) {
        final text = attr.asString;
        if (text != null && text.isNotEmpty) cur.constText ??= text;
      }
      if (attr.attribute == HeapAttribute.shortText) {
        final text = attr.asciiText;
        if (text != null && text.length == _attrScalarBytes(attr.width)) {
          cur.label ??= text;
        }
      }
      if (attr.attribute == HeapAttribute.constValue &&
          cur.objectClass == BdHeapObjectClass.constant &&
          cur.constValueRaw == null) {
        cur.constValueRaw = _attrFlatBytes(attr);
        cur.constValueScalar = _attrScalarBytes(attr.width) != null;
      }
      if (attr.attribute == HeapAttribute.formatStyle) {
        final bytes = _attrFlatBytes(attr);
        if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
          cur.displayFormat ??= String.fromCharCodes(bytes);
        }
      }
      if (attr.attribute == HeapAttribute.cosmColorB && cur.objectClass.isLabel) {
        cur.labelModeWord ??= attr.asInt;
      }
      if (attr.attribute == HeapAttribute.termBounds) cur.termBounds ??= attr.asRect;
      if (attr.attribute == HeapAttribute.termBMPs) cur.termBmp ??= attr.asInt;
      if (attr.attribute == HeapAttribute.typeDescIndex) cur.typeDescIdx ??= attr.asInt;
      if (attr.attribute == HeapAttribute.objFlags) cur.objFlags ??= attr.asInt;
      if (attr.attribute == HeapAttribute.primResID &&
          cur.objectClass == BdHeapObjectClass.primitive &&
          attr.width == HeapAttrWidth.u16) {
        cur.primResId ??= attr.asInt;
      }
      if (attr.attribute == HeapAttribute.dIdx && cur.objectClass.isMultiFrameStructure) {
        cur.dIdx ??= attr.asInt;
      }
      if (attr.attribute == HeapAttribute.compressedWireTable && cur.objectClass == BdHeapObjectClass.signal) {
        if (attr.width == HeapAttrWidth.container) {
          cur.wireTableRaw ??= attr.rawValueBytes;
        } else {
          final scalarBytes = _attrScalarBytes(attr.width);
          final value = attr.asInt;
          if (scalarBytes != null && scalarBytes > 0 && value != null) {
            final table = Uint8List(scalarBytes);
            for (var b = 0; b < scalarBytes; b++) {
              table[b] = (value >> (8 * (scalarBytes - 1 - b))) & 0xff;
            }
            cur.wireTableRaw ??= table;
          }
        }
      }
      if (attr.attribute == HeapAttribute.selectDefaultCase && cur.objectClass == BdHeapObjectClass.caseStructure) {
        final frame = attr.asInt;
        if (frame != null && frame != kViNoDefaultFrame) cur.defaultFrameIndex ??= frame;
      }
      if (attr.attribute == HeapAttribute.lastSignalKind && cur.objectClass == BdHeapObjectClass.signal) {
        final word = attr.asInt;
        if (word != null && word <= 0xffff) cur.lastSignalKind ??= word;
      }
      final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
      final rgb = attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
      if (rgb != null) {
        switch (attr.attribute) {
          case HeapAttribute.backgroundColor:
            cur.bgRgb ??= rgb;
          case HeapAttribute.fgColor:
            cur.fgRgb ??= rgb;
          case HeapAttribute.contentColor:
            cur.contentRgb ??= rgb;
          case HeapAttribute.structColor:
            cur.structRgb ??= rgb;
          case HeapAttribute.borderColor:
            cur.borderRgb ??= rgb;
          case HeapAttribute.plotColor:
            (cur.plotColors.isEmpty ? (cur.plotColors = <int>[]) : cur.plotColors).add(rgb);
          default:
            break;
        }
      }
    }
  }

  for (final object in objects) {
    if (object.end == 0) object.end = length;
  }
  final diagram = ViDiagram(sectionTag: sectionTag, objects: objects, version: version, sectionIndex: sectionIndex);
  final byOid = diagram.byId;

  for (final object in objects) {
    if (!object.objectClass.isLabel) continue;
    final parent = diagram.parentOf(object);
    final local = object.bounds;
    final ownerBounds = parent?.bounds;
    final ownerAbs = parent?.absBounds;
    if (local == null || ownerBounds == null || ownerAbs == null) continue;
    object.absBounds = HeapRect(
      top: ownerAbs.top + local.top,
      left: ownerAbs.left + local.left,
      bottom: ownerAbs.top + local.top + local.height,
      right: ownerAbs.left + local.left + local.width,
    );
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    final b = root.absBounds;
    if (b != null) {
      root.absBounds = HeapRect(
        top: b.top + dTop,
        left: b.left + dLeft,
        bottom: b.bottom + dTop,
        right: b.right + dLeft,
      );
    }
    for (final child in diagram.childrenOf(root)) {
      shiftSubtree(child, dTop, dLeft);
    }
  }

  for (final object in objects) {
    if (object.objectClass != BdHeapObjectClass.flatSequence || object.absBounds == null) continue;
    for (final frame in diagram.childrenOf(object)) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      final owner = object.absBounds;
      if (frame.objectClass != BdHeapObjectClass.sequenceFrame || local == null || abs == null || owner == null) {
        continue;
      }
      final dTop = owner.top + local.top - abs.top;
      final dLeft = owner.left + local.left - abs.left;
      if (dTop != 0 || dLeft != 0) shiftSubtree(frame, dTop, dLeft);
    }
  }

  for (final object in objects) {
    object.category = classifyObject(objectClass: object.objectClass, termCount: object.termCount);
    object.typeKind = inferTypeKind(typeKindEvidence[object.index]);
  }

  for (final object in objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 12) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (po.objectClass.isControlTerminal) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
      parentOid = po.parentOid;
      depth++;
    }
  }

  for (final object in objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= helpText;
        break;
      }
      parentOid = po.parentOid;
    }
  }

  for (final object in objects) {
    if (object.category != BdObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (object.parentOid == null || byOid[object.parentOid]?.objectClass != BdHeapObjectClass.frame) continue;
    final cs = diagram.childrenOf(object);
    if (cs.isEmpty) continue;
    final hasStructural = cs.any((c) => c.kind == kNodeEndpointDcoKind);
    final hasConnector = cs.any((c) => c.objectClass.isConnectorTerminal);
    if (!hasStructural || hasConnector || object.objectClass is! BdHeapObjectClass) continue;
    object.category = BdObjectKind.node;
  }

  for (final object in objects) {
    if (object.category != BdObjectKind.node || object.label != null) continue;
    final caps = diagram
        .childrenOf(object)
        .where((c) => c.objectClass.isLabel)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }

  _reanchorScrolledControls(diagram);
  return diagram;
}

/// The attributes the model reads; the walk decodes no other.
const Set<HeapAttribute> _modelAttributes = {
  HeapAttribute.backgroundColor,
  HeapAttribute.borderColor,
  HeapAttribute.compressedWireTable,
  HeapAttribute.conNum,
  HeapAttribute.constValue,
  HeapAttribute.contentColor,
  HeapAttribute.cosmColorB,
  HeapAttribute.dIdx,
  HeapAttribute.fgColor,
  HeapAttribute.formatStyle,
  HeapAttribute.lastSignalKind,
  HeapAttribute.objFlags,
  HeapAttribute.plotColor,
  HeapAttribute.primResID,
  HeapAttribute.selectDefaultCase,
  HeapAttribute.shortText,
  HeapAttribute.stdNumMax,
  HeapAttribute.stdNumMin,
  HeapAttribute.structColor,
  HeapAttribute.termBMPs,
  HeapAttribute.termBounds,
  HeapAttribute.typeDescIndex,
};

final List<bool> _modelAttributeRaws = () {
  final table = List<bool>.filled(kHeapRawIdCount, false);
  for (final attribute in _modelAttributes) {
    table[attribute.raw] = true;
  }
  return table;
}();

List<String> _parseEnumItems(List<int> payload) {
  final out = <String>[];
  var i = 0;
  while (i < payload.length) {
    final len = payload[i++];
    if (len == 0) continue;
    if (i + len > payload.length) return const [];
    final text = String.fromCharCodes(payload.sublist(i, i + len));
    i += len;
    if (!text.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return const [];
    out.add(text);
  }
  return out;
}

void _reanchorScrolledControls(ViDiagram diagram) {
  final objects = diagram.objects;
  final byOid = diagram.byId;
  int? reanchorViewport(ViHeapObject object) {
    var parentOid = object.parentOid;
    for (var depth = 0; parentOid != null && depth < objects.length; depth++) {
      final po = byOid[parentOid];
      if (po == null) return null;
      if (po.objectClass.isPane) return po.oid;
      if (po.objectClass.isControlTerminal || po.bounds != null) return null;
      parentOid = po.parentOid;
    }
    return null;
  }

  final groups = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (!object.objectClass.isControlTerminal || object.bounds == null || object.absBounds == null) {
      continue;
    }
    final viewport = reanchorViewport(object);
    if (viewport != null) (groups[viewport] ??= <ViHeapObject>[]).add(object);
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final seen = <ViHeapObject>{root};
    final expanded = <int>{};
    final work = <ViHeapObject>[root];
    while (work.isNotEmpty) {
      final object = work.removeLast();
      final bounds = object.absBounds;
      if (bounds != null) {
        object.absBounds = HeapRect(
          top: bounds.top + dTop,
          left: bounds.left + dLeft,
          bottom: bounds.bottom + dTop,
          right: bounds.right + dLeft,
        );
      }
      if (!expanded.add(object.oid)) continue;
      final cs = diagram.childrenOf(object);
      if (cs.isNotEmpty) {
        for (final child in cs) {
          if (seen.add(child)) work.add(child);
        }
      }
    }
  }

  for (final MapEntry(key: vOid, value: controls) in groups.entries) {
    final viewport = byOid[vOid];
    if (viewport?.absBounds == null) continue;
    final minTop = controls.map((c) => c.bounds!.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewport!.absBounds!.top + (control.bounds!.top - minTop);
      final newLeft = viewport.absBounds!.left + (control.bounds!.left - minLeft);
      shiftSubtree(control, newTop - control.absBounds!.top, newLeft - control.absBounds!.left);
    }
  }
}

/// The drawing kind of a data type, or null for one the diagram does not classify.
ViTypeKind? typeKindOfDataType(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => ViTypeKind.numericInt,
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => ViTypeKind.numericFloat,
  ViDataType.enumU8 || ViDataType.enumU16 || ViDataType.enumU32 => ViTypeKind.enumRing,
  ViDataType.boolean => ViTypeKind.boolean,
  ViDataType.string || ViDataType.cString || ViDataType.pascalString || ViDataType.subString => ViTypeKind.string,
  ViDataType.path => ViTypeKind.path,
  ViDataType.cluster => ViTypeKind.cluster,
  ViDataType.array || ViDataType.subArray || ViDataType.arrayDataPointer => ViTypeKind.array,
  ViDataType.refnum => ViTypeKind.refnum,
  _ => null,
};

/// Joins the diagrams to the type pool: marks indicators from their `objFlags`, resolves each
/// `typeDescIdx` through [table] (the data-space type map) offset by [typeIndexBase], copies
/// the result to objects that reach a DCO through `dcoRef`, then decodes constant values.
void resolveDataSpaceTypes({
  required List<ViType> pool,
  required List<int> table,
  required int? typeIndexBase,
  required List<ViDiagram> blockDiagrams,
  required List<ViDiagram> frontPanelDiagrams,
}) {
  final diagrams = [...blockDiagrams, ...frontPanelDiagrams];

  ViHeapObject? findDco(ViDiagram own, int oid) {
    final local = own.byId[oid];
    if (local != null) return local;
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  final base = typeIndexBase;
  final resolvable = pool.isNotEmpty && table.isNotEmpty && base != null;

  ViType? resolve(int index) {
    final ti = base! + index;
    if (ti < 0 || ti >= table.length) return null;
    final pi = table[ti];
    return pi >= 0 && pi < pool.length ? pool[pi] : null;
  }

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final index = object.typeDescIdx;
      if (index == null) continue;
      if (object.objectClass == FpHeapObjectClass.dco) object.isIndicator = object.hasFlag(ViObjFlag.indicator);
      if (!resolvable) continue;
      final type = resolve(index);
      if (type == null) continue;
      final kind = typeKindOfDataType(type.kind);
      if (kind != null) object.typeKind = kind;
      object.dataType = type.kind;
      object.resolvedType = type;
      if (type case ViArrayType(:final elementIndex) when elementIndex < pool.length) {
        final elementType = pool[elementIndex];
        object.resolvedElementType = elementType;
        if (elementType.kind == ViDataType.cluster) {
          object.resolvedElementMembers = clusterFields(elementType, pool);
        }
      }
      if (type.kind == ViDataType.cluster) {
        object.resolvedMembers = clusterFields(type, pool);
      }
      final typeName = type.label?.trim();
      if (typeName != null && typeName.isNotEmpty) {
        object.typeName ??= typeName;
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final dcoRefs = object.refsOf(HeapRefKind.dcoRef);
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(diagram, dcoRefs.first);
      object.isIndicator ??= dco?.isIndicator;
      if (!resolvable || object.typeDescIdx != null || dco == null) continue;
      if (dco.typeKind != ViTypeKind.unknown) object.typeKind = dco.typeKind;
      object.dataType ??= dco.dataType;
      object.resolvedType ??= dco.resolvedType;
      object.resolvedElementType ??= dco.resolvedElementType;
      if (object.resolvedMembers.isEmpty) {
        object.resolvedMembers = dco.resolvedMembers;
      }
      if (object.resolvedElementMembers.isEmpty) {
        object.resolvedElementMembers = dco.resolvedElementMembers;
      }
      object.typeName ??= dco.typeName;
    }
  }

  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}

int? _flatNumericSize(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

num _flatNumericAt(Uint8List flat, int offset, ViDataType kind, int size) {
  if (kind == ViDataType.sgl) return ByteData.sublistView(flat).getFloat32(offset);
  if (kind == ViDataType.dbl) return ByteData.sublistView(flat).getFloat64(offset);
  var value = 0;
  for (var i = 0; i < size; i++) {
    value = (value << 8) | flat[offset + i];
  }
  final signed = kind == ViDataType.i8 || kind == ViDataType.i16 || kind == ViDataType.i32 || kind == ViDataType.i64;
  return signed ? value.toSigned(8 * size) : value;
}

// TODO: payloads stored wider than their numeric type, and arrays of elements other than numbers
// and strings, are not decoded.
void _typedBdConstDecode(ViHeapObject object) {
  final flat = object.constValueRaw;
  final type = object.resolvedType;
  if (flat == null || type == null) return;
  final scalarSize = _flatNumericSize(type.kind);
  if (scalarSize != null) {
    if (flat.isEmpty || flat.length > scalarSize) return;
    if (flat.length < scalarSize && (type.kind == ViDataType.sgl || type.kind == ViDataType.dbl)) {
      return;
    }
    final size = flat.length;
    final kind = size < scalarSize ? ViDataType.u64 : type.kind;
    final value = _flatNumericAt(flat, 0, kind, size);
    if (value is double && !value.isFinite) return;
    object.constNumeric = value;
    return;
  }
  if (type.kind == ViDataType.string) {
    if (object.constValueScalar || flat.length < 4) return;
    final declared = ByteData.sublistView(flat).getUint32(0);
    if (4 + declared == flat.length) {
      object.constText = String.fromCharCodes(flat, 4);
    } else if (declared == 0 && flat.length == 5 && flat[4] == 0) {
      object.constText = '';
    }
    return;
  }
  if (type is! ViArrayType) return;
  final element = object.resolvedElementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount < 1 || dimCount > 8) return;
  final elementSize = _flatNumericSize(element.kind);
  if ((elementSize == null && element.kind != ViDataType.string) || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var d = 0; d < dimCount; d++) view.getUint32(4 * d)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (elementSize == null) {
    final texts = <String>[];
    var at = 4 * dimCount;
    for (var i = 0; i < count; i++) {
      if (at + 4 > flat.length) return;
      final length = view.getUint32(at);
      if (at + 4 + length > flat.length) return;
      texts.add(String.fromCharCodes(flat, at + 4, at + 4 + length));
      at += 4 + length;
    }
    if (at != flat.length && !emptyPadded) return;
    object.constArrayDims = dims;
    object.constTextArray = texts;
    return;
  }
  final expected = 4 * dimCount + count * elementSize;
  if (flat.length != expected && !emptyPadded) return;
  object.constArrayDims = dims;
  object.constArray = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

/// Fills the `const*` fields of every constant DCO: through its resolved type first, then
/// through [decodeBdConstantValue] for the fields still unset.
void decodeBdConstValues(ViDiagram diagram) {
  bool subtreeHasItems(ViHeapObject o, [int depth = 0]) {
    if (o.items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in diagram.childrenOf(o)) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final object in diagram.objects) {
    if (object.objectClass != BdHeapObjectClass.constant || object.constValueRaw == null) continue;
    _typedBdConstDecode(object);
    final kids = diagram.childrenOf(object);
    if (kids.isEmpty) continue;
    final carrier = kids.first.objectClass;
    final wantsItems = carrier == BdHeapObjectClass.enumRing || carrier == BdHeapObjectClass.typeDefinition;
    final value = decodeBdConstantValue(
      carrier: carrier,
      flat: object.constValueRaw,
      scalar: object.constValueScalar,
      hasEnumItems: wantsItems && subtreeHasItems(object),
    );
    if (value is bool) object.constBool ??= value;
    if (value is num) object.constNumeric ??= value;
    if (value is String) object.constText ??= value;
  }
}
