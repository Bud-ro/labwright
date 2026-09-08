import 'dart:math';
import 'dart:typed_data';

import 'blocks/type_pool.dart';
import 'diagram_object.dart';
import 'heap.dart';
import 'selector_range.dart';
import 'signal_type.dart';
import 'wire_route.dart';

export 'diagram_object.dart';
export 'selector_range.dart';
export 'signal_type.dart';
export 'wire_route.dart';

part 'graph/constant_values.dart';
part 'graph/diagram_builder.dart';
part 'graph/type_resolution.dart';
part 'graph/wire_solver.dart';

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

class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects, this.version});

  final String sectionTag;

  final String? version;

  final List<ViHeapObject> objects;

  late final Map<int, ViHeapObject> byId = {for (final object in objects) object.oid: object};

  Iterable<ViHeapObject> get roots => objects.where((object) => object.parentOid == null);

  Iterable<ViHeapObject> children(int oid) => childrenByOid[oid] ?? const <ViHeapObject>[];

  List<ViHeapObject> framesOf(ViHeapObject structure) => [
    for (final child in children(structure.oid))
      if (child.kind == kViFrameCode) child,
  ];

  int? displayedFrameIndex(ViHeapObject structure) {
    if (!kMultiFrameStructureClasses.contains(structure.objectClass)) return null;
    var frames = 0;
    for (final child in children(structure.oid)) {
      if (child.kind == kViFrameCode) frames++;
    }
    final index = structure.visibleFrameIndex;
    return index < frames ? index : null;
  }

  Iterable<ViHeapObject> get nodes => objects.where((object) => object.absBounds != null);

  late final List<ViWire> wires = [
    for (final object in objects)
      if (object.objectClass == HeapObjectClass.signal) _buildWire(object),
  ];

  late final Map<int, int> _terminalOidByMemberOid = _buildTerminalIndex();

  static const int _ambiguousTerminal = -1;

  Map<int, int> _buildTerminalIndex() {
    final index = <int, int>{};
    for (final object in objects) {
      if (object.termBounds == null) continue;
      for (final target in object.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        final prev = index[target];
        index[target] = (prev == null || prev == object.oid) ? object.oid : _ambiguousTerminal;
      }
    }
    return index;
  }

  ViHeapObject? endpointTerminal(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || !kSignalEndpointDcoKinds.contains(endpoint.kind)) return null;
    final terminalOid = _terminalOidByMemberOid[oid];
    return terminalOid == null || terminalOid == _ambiguousTerminal ? null : byId[terminalOid];
  }

  late final Map<int, List<ViHeapObject>> childrenByOid = _childrenByParentOid(objects);

  late final Map<int, int> _dcoOidByTerminalOid = _buildTerminalDcoIndex();

  Map<int, int> _buildTerminalDcoIndex() {
    final index = <int, int>{};
    for (final terminal in objects) {
      if (terminal.termBounds == null) continue;
      for (final target in terminal.typedRefs[HeapRefKind.childRef] ?? const <int>[]) {
        final candidate = byId[target];
        if (candidate == null || !kSignalEndpointDcoKinds.contains(candidate.kind)) continue;
        if (!(candidate.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]).contains(terminal.oid)) continue;
        final prev = index[terminal.oid];
        index[terminal.oid] = (prev == null || prev == candidate.oid) ? candidate.oid : _ambiguousTerminal;
      }
    }
    return index;
  }

  ViHeapObject? terminalDco(int oid) {
    final dcoOid = _dcoOidByTerminalOid[oid];
    return dcoOid == null || dcoOid == _ambiguousTerminal ? null : byId[dcoOid];
  }

  bool terminalGlyphHidden(int oid) => ((terminalDco(oid)?.objFlags ?? 0) & kTerminalGlyphHiddenFlag) != 0;

  ViHeapObject? endpointConstant(int oid) {
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind) return null;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
      if (child.objectClass == HeapObjectClass.bdConstDco) return child;
    }
    return null;
  }

  HeapRect? endpointConstantBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds != null) return child.absBounds;
    }
    return null;
  }

  HeapRect? endpointConstantElementBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final constant = endpointConstant(oid);
    if (constant == null) return null;
    for (final child in childrenByOid[constant.oid] ?? const <ViHeapObject>[]) {
      if (child.absBounds == null) continue;
      if (child.objectClass != HeapObjectClass.caseOrSequence) return null;
      HeapRect? element;
      for (final kid in childrenByOid[child.oid] ?? const <ViHeapObject>[]) {
        final kidBounds = kid.absBounds;
        if (kid.objectClass == HeapObjectClass.controlChrome ||
            kid.objectClass == HeapObjectClass.controlLabel ||
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

  HeapRect? endpointTerminalBounds(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
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

  ({List<ViPoint> candidates, bool wideRow})? dcoChildTerminalAttach(int oid) {
    if (_predatesFrameRelativeTermBounds(version)) return null;
    final endpoint = byId[oid];
    if (endpoint == null || endpoint.kind != kNodeEndpointDcoKind || endpoint.absBounds != null) return null;
    ViHeapObject? part;
    for (final child in childrenByOid[oid] ?? const <ViHeapObject>[]) {
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

  ViPoint? wireAttachPoint(int oid) =>
      _attachPointFrom(endpointTerminalBounds(oid) ?? endpointConstantBounds(oid), oid);

  ViPoint? _attachPointFrom(HeapRect? attachRect, int oid) {
    var rect = attachRect;
    if (rect == null) {
      if (_predatesFrameRelativeTermBounds(version)) return null;
      final endpoint = byId[oid];
      if (endpoint == null || endpoint.objectClass != HeapObjectClass.bdLeaf) return null;
      rect = endpoint.absBounds;
      if (rect == null) return null;
    }
    var x = rect.left + (rect.right - rect.left) ~/ 2;
    if (attachRect != null) {
      final terminalKind = endpointTerminal(oid)?.kind;
      if (terminalKind == kRightShiftRegisterClass) {
        x -= kShiftRegisterColumnLeftOffset;
      } else if (terminalKind == kLeftShiftRegisterClass) {
        x += kShiftRegisterColumnRightOffset;
      }
    }
    return (x: x, y: rect.top + (rect.bottom - rect.top) ~/ 2);
  }

  ViPoint? _stripFarTarget(int oid, HeapRect? attachRect, ViPoint? attach) {
    if (attachRect == null || attach == null) return null;
    if (attachRect.right - attachRect.left != kTerminalStripColumnWidth) return null;
    if (!kNodeTerminalStripClasses.contains(endpointTerminal(oid)?.kind)) return null;
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
    final seen = <int>{};
    while (object != null && seen.add(object.oid)) {
      if (object.absBounds != null) return object;
      final parentOid = object.parentOid;
      object = parentOid == null ? null : byId[parentOid];
    }
    return null;
  }
}

Map<int, List<ViHeapObject>> _childrenByParentOid(List<ViHeapObject> objects) {
  final kids = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (object.parentOid != null) (kids[object.parentOid!] ??= <ViHeapObject>[]).add(object);
  }
  return kids;
}
