library;

import 'dart:math' show max, min;

import 'blocks/prim_ops.dart';
import 'graph.dart';
import 'heap.dart' show HeapRect;

const Set<int> kSubViCallNodeCodes = {0x31, 0x32, 0xc5, 0x104, 0x103, 0x8c, 0x124};

String? primOpGlyph(PrimOp? op) => switch (op) {
  PrimOp.add => '+',
  PrimOp.subtract => '−',
  PrimOp.multiply => '×',
  PrimOp.divide => '÷',
  PrimOp.increment => '+1',
  PrimOp.decrement => '−1',
  PrimOp.squareRoot => 'sqrt',
  PrimOp.and => '&',
  PrimOp.or => 'or',
  PrimOp.exclusiveOr => 'xor',
  PrimOp.not => '!',
  PrimOp.equal => '=',
  PrimOp.notEqual => '≠',
  PrimOp.greater => '>',
  PrimOp.less => '<',
  PrimOp.equalToZero => '=0',
  PrimOp.notEqualToZero => '≠0',
  PrimOp.greaterThanZero => '>0',
  PrimOp.lessThanZero => '<0',
  PrimOp.greaterOrEqualToZero => '≥0',
  PrimOp.lessOrEqualToZero => '≤0',
  PrimOp.select => 'sel',
  PrimOp.toByteInteger => 'I8',
  PrimOp.toWordInteger => 'I16',
  PrimOp.toLongInteger => 'I32',
  PrimOp.toUnsignedByteInteger => 'U8',
  PrimOp.toUnsignedWordInteger => 'U16',
  PrimOp.toUnsignedLongInteger => 'U32',
  PrimOp.toSinglePrecisionFloat => 'SGL',
  PrimOp.toDoublePrecisionFloat => 'DBL',
  PrimOp.typeCast => 'cast',
  PrimOp.logicalShift => 'shl',
  PrimOp.rotateLeftWithCarry => 'rlc',
  PrimOp.rotateRightWithCarry => 'rrc',
  PrimOp.arraySize => 'siz',
  PrimOp.buildPath => 'pth',
  PrimOp.stringLength => 'len',
  _ => null,
};

Map<int, String> bdConstValueTexts(ViDiagram diagram) {
  final byId = diagram.byId;
  final out = <int, String>{};
  for (final object in diagram.objects) {
    if (object.category != ViObjectKind.terminal) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    final parent = byId[object.parentOid ?? -1];
    final value = parent?.objectClass == HeapObjectClass.bdConstDco ? parent!.constNumeric : null;
    if (value == null) continue;
    out[object.oid] = bdFormatConstValue(
      value,
      bdDisplayFormatOf(diagram, object.oid),
    );
  }
  return out;
}

// TODO: the constant display mode (normal, backslash codes, hex) is not decoded.
String? bdDrawnConstText(ViHeapObject? object) {
  final text = object?.constText;
  if (text == null || text.codeUnits.any((code) => code < 0x20 || code >= 0x7f)) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? bdDisplayFormatOf(ViDiagram diagram, int oid) {
  for (final part in diagram.children(oid)) {
    if (part.objectClass == HeapObjectClass.numericDisplay && part.displayFormat != null) {
      return part.displayFormat;
    }
  }
  return null;
}

String? bdFormatConversion(String? format) =>
    format == null ? null : RegExp(r'^%[-+ #0]*\d*(?:\.\d+)?([a-zA-Z])').firstMatch(format)?.group(1);

// TODO: negative integers under a radix format are not decoded; they fall back to decimal.
String bdFormatConstValue(num value, String? format) {
  final match = format == null ? null : RegExp(r'^%([-+ #0]*)(\d*)(?:\.\d+)?([a-zA-Z])').firstMatch(format);
  final radix = switch (match?.group(3)) {
    'x' || 'X' => 16,
    'o' => 8,
    'b' || 'B' => 2,
    _ => null,
  };
  final whole = value is double && value == value.roundToDouble() ? value.toInt() : value;
  if (radix != null && whole is int && whole >= 0) {
    var text = whole.toRadixString(radix).toUpperCase();
    final width = int.tryParse(match!.group(2) ?? '') ?? 0;
    if (match.group(1)!.contains('0') && text.length < width) {
      text = text.padLeft(width, '0');
    }
    return text;
  }
  return whole.toString();
}

const Set<HeapObjectClass> kBdTextLabelClasses = {
  HeapObjectClass.controlLabel,
  HeapObjectClass.bdSelectorLabel,
};

({String text, bool isHint}) nodeDisplayLabel(ViHeapObject object) {
  final label = object.label?.trim();
  if (label != null && label.isNotEmpty) return (text: label, isHint: false);
  final cls = object.objectClass.label;
  final match = RegExp(r'^Node \((.+)\)$').firstMatch(cls);
  return (text: match != null ? match.group(1)! : cls, isHint: true);
}

String structureBadge(ViHeapObject object) =>
    object.objectClass == HeapObjectClass.unknown ? 'Structure' : object.objectClass.label;

String? wireframeAnnotation(ViHeapObject o) {
  if (o.category == ViObjectKind.structure) return structureBadge(o);
  final label = o.label;
  final type = o.typeKind == ViTypeKind.unknown ? null : o.typeKind.name;
  if (label != null && type != null) return '$label · $type';
  return label ?? type;
}

({
  Map<HeapObjectClass, int> structuresByClass,
  List<String> labeledNodes,
  int nodeCount,
  Map<ClassConfidence, int> confidence,
})
computeBdOutline(Iterable<ViHeapObject> objects) {
  const notControlFlow = {
    HeapObjectClass.diagramRoot,
    HeapObjectClass.diagramProps,
    HeapObjectClass.diagramFrame,
    HeapObjectClass.rootAux,
  };
  final byClass = <HeapObjectClass, int>{};
  final labeledNodes = <String>[];
  var nodeCount = 0;
  final confidence = <ClassConfidence, int>{};
  for (final object in objects) {
    final objectClass = object.objectClass;
    if (object.category == ViObjectKind.structure) {
      if (notControlFlow.contains(objectClass)) continue;
      byClass[objectClass] = (byClass[objectClass] ?? 0) + 1;
    } else if (object.category == ViObjectKind.node) {
      nodeCount++;
      final label = nodeDisplayLabel(object);
      if (!label.isHint && !labeledNodes.contains(label.text)) {
        labeledNodes.add(label.text);
      }
    } else {
      continue;
    }
    confidence[objectClass.confidence] = (confidence[objectClass.confidence] ?? 0) + 1;
  }
  return (
    structuresByClass: byClass,
    labeledNodes: labeledNodes,
    nodeCount: nodeCount,
    confidence: confidence,
  );
}

const Set<HeapObjectClass> _controlTerminalDrawClasses = {
  HeapObjectClass.numericControl,
  HeapObjectClass.booleanOrClusterControl,
  HeapObjectClass.enumRingControl,
  HeapObjectClass.pathControl,
  HeapObjectClass.stringOrArrayControl,
  HeapObjectClass.controlTerminal55,
  HeapObjectClass.controlTerminal10c,
  HeapObjectClass.constantC2,
  HeapObjectClass.controlRare56,
};

bool _isInlinedSubViControl(
  ViHeapObject o,
  Map<int, ViHeapObject> byId,
  Map<int, List<ViHeapObject>> childrenByOid,
) {
  if (!_controlTerminalDrawClasses.contains(o.objectClass)) return false;
  var parentOid = o.parentOid;
  final seen = <int>{};
  var underConstOrStruct = false;
  while (parentOid != null && seen.add(parentOid)) {
    final parent = byId[parentOid];
    if (parent == null) break;
    if (parent.objectClass == HeapObjectClass.bdConstDco || parent.kind == kNodeEndpointDcoKind) {
      if (parent.objectClass == HeapObjectClass.bdConstDco &&
          o.typeKind == ViTypeKind.numericInt &&
          (parent.constNumeric != null || parent.constBool != null || parent.constText != null)) {
        return false;
      }
      underConstOrStruct = true;
      break;
    }
    parentOid = parent.parentOid;
  }
  if (!underConstOrStruct) return false;
  final kids = childrenByOid[o.oid];
  if (kids == null) return false;
  return kids.any(
    (c) => c.objectClass == HeapObjectClass.controlLabel && !c.isLabelHidden && (c.label?.trim().isNotEmpty ?? false),
  );
}

bool _isScaffolding(ViHeapObject o, Map<int, ViHeapObject> byId) {
  if (o.objectClass == HeapObjectClass.controlChrome || o.objectClass == HeapObjectClass.contentViewport) return true;
  if (o.objectClass == HeapObjectClass.bdPolySelector) return true;
  if (o.objectClass == HeapObjectClass.connectorTerminal && o.bounds == null) return true;
  if (o.objectClass == HeapObjectClass.numericDisplay ||
      o.objectClass == HeapObjectClass.controlSubPart ||
      o.objectClass == HeapObjectClass.nodeTerminalCluster ||
      o.objectClass == HeapObjectClass.enumItemList) {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 64) {
      final parent = byId[parentOid];
      if (parent == null) break;
      if (kControlTerminalClasses.contains(parent.objectClass)) return true;
      parentOid = parent.parentOid;
      depth++;
    }
  }
  {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 8) {
      final parent = byId[parentOid];
      if (parent == null) break;
      if (parent.objectClass == HeapObjectClass.loop &&
          parent.absBounds != null &&
          parent.absBounds!.width <= 40 &&
          parent.absBounds!.height <= 24) {
        return true;
      }
      parentOid = parent.parentOid;
      depth++;
    }
  }
  return false;
}

Set<ViHeapObject> membersOf(ViHeapObject? o, Map<int, ViHeapObject> byId) {
  if (o == null) return const {};
  return {
    for (final oid in o.memberOids)
      if (byId[oid] case final m? when m.absBounds != null && !identical(m, o) && !_isScaffolding(m, byId)) m,
  };
}

Set<ViHeapObject> nodesWithin(
  ViHeapObject structure,
  Iterable<ViHeapObject> objects,
) {
  final structureBounds = structure.absBounds;
  if (structureBounds == null) return const {};
  final out = <ViHeapObject>{};
  for (final object in objects) {
    if (identical(object, structure)) continue;
    if (object.category != ViObjectKind.node && object.category != ViObjectKind.structure) {
      continue;
    }
    final bounds = object.absBounds;
    if (bounds == null) continue;
    if (bounds.left < structureBounds.left ||
        bounds.top < structureBounds.top ||
        bounds.right > structureBounds.right ||
        bounds.bottom > structureBounds.bottom) {
      continue;
    }
    if (bounds == structureBounds) continue;
    out.add(object);
  }
  return out;
}

Set<int> bdHiddenFrameOids(ViDiagram diagram) {
  final childrenByOid = diagram.childrenByOid;
  final hidden = <int>{};

  void hideSubtree(ViHeapObject root) {
    hidden.add(root.oid);
    for (final child in childrenByOid[root.oid] ?? const <ViHeapObject>[]) {
      hideSubtree(child);
    }
  }

  for (final structure in diagram.objects) {
    if (structure.category != ViObjectKind.structure) continue;
    final box = structure.absBounds;
    if (box == null || box.width <= 0 || box.height <= 0) continue;
    final frames = diagram.framesOf(structure);
    if (frames.length < 2) continue;

    final visible = diagram.displayedFrameIndex(structure);
    if (visible != null) {
      for (var i = 0; i < frames.length; i++) {
        if (i != visible) hideSubtree(frames[i]);
      }
      continue;
    }

    final inBoxCounts = <int>[];
    final inBoxBoxes = <HeapRect?>[];
    for (final frame in frames) {
      var count = 0;
      var l = 1 << 30, t = 1 << 30, r = -(1 << 30), b = -(1 << 30);
      void visit(ViHeapObject o) {
        final bounds = o.absBounds;
        if (bounds != null && bounds.width > 0 && bounds.height > 0) {
          final cx = (bounds.left + bounds.right) / 2, cy = (bounds.top + bounds.bottom) / 2;
          if (cx >= box.left - 8 && cx <= box.right + 8 && cy >= box.top - 8 && cy <= box.bottom + 8) {
            count++;
            if (bounds.left < l) l = bounds.left;
            if (bounds.top < t) t = bounds.top;
            if (bounds.right > r) r = bounds.right;
            if (bounds.bottom > b) b = bounds.bottom;
          }
        }
        for (final child in childrenByOid[o.oid] ?? const <ViHeapObject>[]) {
          visit(child);
        }
      }

      visit(frame);
      inBoxCounts.add(count);
      inBoxBoxes.add(
        count == 0 ? null : HeapRect(top: t, left: l, bottom: b, right: r),
      );
    }
    final candidates = [
      for (var i = 0; i < frames.length; i++)
        if (inBoxCounts[i] > 0) i,
    ];
    if (candidates.length < 2) {
      for (var i = 0; i < frames.length; i++) {
        if (candidates.isEmpty ? i > 0 : i != candidates.single) {
          hideSubtree(frames[i]);
        }
      }
      continue;
    }
    var overlapping = false;
    for (var i = 0; i < candidates.length && !overlapping; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        final one = inBoxBoxes[candidates[i]]!;
        final two = inBoxBoxes[candidates[j]]!;
        final overlapWidth = min(one.right, two.right) - max(one.left, two.left);
        final overlapHeight = min(one.bottom, two.bottom) - max(one.top, two.top);
        if (overlapWidth <= 0 || overlapHeight <= 0) continue;
        final minArea = min(one.width * one.height, two.width * two.height);
        if (minArea > 0 && overlapWidth * overlapHeight / minArea > 0.2) {
          overlapping = true;
          break;
        }
      }
    }
    if (!overlapping) continue;
    var fullest = candidates.first;
    for (final i in candidates) {
      if (inBoxCounts[i] > inBoxCounts[fullest]) fullest = i;
    }
    for (var i = 0; i < frames.length; i++) {
      if (i != fullest) hideSubtree(frames[i]);
    }
  }
  return hidden;
}

List<ViWire> bdVisibleWires(ViDiagram diagram) {
  final hidden = bdHiddenFrameOids(diagram)..addAll(bdInlinedInstanceOids(diagram));
  final byId = diagram.byId;

  HeapRect? reanchor(int endpointOid) {
    var cur = byId[endpointOid];
    var depth = 0;
    while (cur != null && depth++ < 64) {
      final bounds = cur.absBounds;
      if (!hidden.contains(cur.oid) && bounds != null && bounds.width > 0 && bounds.height > 0) {
        return cur.parentOid == null ? null : bounds;
      }
      cur = cur.parentOid == null ? null : byId[cur.parentOid!];
    }
    return null;
  }

  final out = <ViWire>[];
  for (final wire in diagram.wires) {
    if (hidden.contains(wire.signalOid)) continue;
    var patched = false;
    var sourcePatched = false;
    final anchors = <HeapRect?>[];
    for (var i = 0; i < wire.endpointAnchors.length; i++) {
      final anchor = wire.endpointAnchors[i];
      if (anchor != null && anchor.width > 0 && anchor.height > 0) {
        anchors.add(anchor);
        continue;
      }
      final attach = i < wire.endpointAttachRects.length ? wire.endpointAttachRects[i] : null;
      final resolved = (attach != null && attach.width > 0 && attach.height > 0)
          ? attach
          : reanchor(wire.endpointOids[i]);
      anchors.add(resolved);
      if (resolved != null) {
        patched = true;
        if (i == 0) sourcePatched = true;
      }
    }
    final boxes = anchors.whereType<HeapRect>().toList();
    if (boxes.length < 2) continue;
    final first = boxes.first;
    if (boxes.every((box) => box == first)) continue;
    out.add(
      patched
          ? ViWire(
              signalOid: wire.signalOid,
              endpointOids: wire.endpointOids,
              endpointAnchors: anchors,
              endpointAttachRects: wire.endpointAttachRects,
              route: sourcePatched ? null : wire.route,
              routePoints: wire.routePoints,
              routePointsFidelity: wire.routePointsFidelity,
              routeClosingStep: wire.routeClosingStep,
              routeHeadSlack: wire.routeHeadSlack,
              routeTree: wire.routeTree,
              signalType: wire.signalType,
            )
          : wire,
    );
  }
  return out;
}

Set<int> bdInlinedInstanceOids(ViDiagram diagram) {
  final childrenByOid = diagram.childrenByOid;
  final out = <int>{};
  void collect(ViHeapObject root) {
    for (final child in childrenByOid[root.oid] ?? const <ViHeapObject>[]) {
      if (out.add(child.oid)) collect(child);
    }
  }

  for (final object in diagram.objects) {
    if (object.kind == 0x105) collect(object);
  }
  return out;
}

Map<int, List<({HeapRect box, int bmp})>> bdStructureTerminals(
  ViDiagram diagram,
) {
  final byId = diagram.byId;
  final out = <int, List<({HeapRect box, int bmp})>>{};
  for (final object in diagram.objects) {
    final box = object.termBounds;
    final bmp = object.termBmp;
    if (box == null || bmp == null) continue;
    if (box.width <= 0 || box.height <= 0) continue;
    if (diagram.terminalGlyphHidden(object.oid)) continue;
    var cur = byId[object.parentOid ?? -1];
    var depth = 0;
    while (cur != null && cur.category != ViObjectKind.structure && depth++ < 8) {
      cur = byId[cur.parentOid ?? -1];
    }
    if (cur == null || cur.category != ViObjectKind.structure) continue;
    (out[cur.oid] ??= []).add((box: box, bmp: bmp));
  }
  return out;
}

bool _nestedInStructure(ViHeapObject object, Map<int, ViHeapObject> byId) {
  var cur = byId[object.parentOid ?? -1];
  var depth = 0;
  while (cur != null && depth++ < 16) {
    if (cur.category == ViObjectKind.structure && cur.parentOid != null) {
      return true;
    }
    cur = byId[cur.parentOid ?? -1];
  }
  return false;
}

List<ViHeapObject> bdDrawableObjects(ViDiagram diagram) {
  final byId = diagram.byId;
  final hidden = bdHiddenFrameOids(diagram)..addAll(bdInlinedInstanceOids(diagram));
  final childrenByOid = diagram.childrenByOid;
  return [
    for (final object in diagram.objects)
      if (object.absBounds != null &&
          object.absBounds!.isValid &&
          (object.category == ViObjectKind.wire || (object.absBounds!.width > 0 && object.absBounds!.height > 0)) &&
          object.absBounds!.width < 8000 &&
          object.absBounds!.height < 8000 &&
          !hidden.contains(object.oid) &&
          !(object.objectClass == HeapObjectClass.bdGlyph &&
              (object.absBounds!.left < 0 || object.absBounds!.top < 0 || _nestedInStructure(object, byId))) &&
          !_escapesConstantBox(object, byId) &&
          !_escapesStructureBox(object, byId) &&
          !(kBdTextLabelClasses.contains(object.objectClass) &&
              object.absBounds!.left == 0 &&
              object.absBounds!.bottom == 0) &&
          !_isInlinedSubViControl(object, byId, childrenByOid) &&
          !_isScaffolding(object, byId))
        object,
  ];
}

bool _escapesConstantBox(ViHeapObject object, Map<int, ViHeapObject> byId) {
  final chain = <ViHeapObject>[];
  var cur = object;
  var depth = 0;
  var underConst = false;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) break;
    if (parent.objectClass == HeapObjectClass.bdConstDco) {
      underConst = true;
      break;
    }
    chain.add(parent);
    cur = parent;
  }
  if (!underConst) return false;
  HeapRect? anchor;
  for (final shell in chain.reversed) {
    final bounds = shell.absBounds;
    if (bounds != null && bounds.width > 0 && bounds.height > 0) {
      anchor = bounds;
      break;
    }
  }
  final box = anchor;
  if (box == null) return false;
  bool outside(HeapRect b) => b.right <= box.left || b.left >= box.right || b.bottom <= box.top || b.top >= box.bottom;
  for (final ancestor in chain) {
    final bounds = ancestor.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (identical(bounds, box)) continue;
    if (outside(bounds)) return true;
  }
  if (kBdTextLabelClasses.contains(object.objectClass)) return false;
  final bounds = object.absBounds;
  return bounds != null && bounds.width > 0 && bounds.height > 0 && outside(bounds);
}

bool _escapesStructureBox(
  ViHeapObject object,
  Map<int, ViHeapObject> byId, {
  int slack = 32,
}) {
  if (kBdTextLabelClasses.contains(object.objectClass)) return false;
  if (object.category == ViObjectKind.wire) return false;
  final bounds = object.absBounds;
  if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return false;
  var cur = object;
  var depth = 0;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) return false;
    if (parent.objectClass == HeapObjectClass.bdWire) return false;
    final box = parent.absBounds;
    if (parent.category == ViObjectKind.structure && box != null && box.width > 0 && box.height > 0) {
      return bounds.right <= box.left - slack ||
          bounds.left >= box.right + slack ||
          bounds.bottom <= box.top - slack ||
          bounds.top >= box.bottom + slack;
    }
    cur = parent;
  }
  return false;
}

Set<String> subViWantedNames(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (kSubViCallNodeCodes.contains(object.kind))
      if (object.label?.trim() case final name? when name.isNotEmpty && _isViFileName(name)) name,
};

bool _isViFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.vi') || lower.endsWith('.vim');
}

List<ViHeapObject> bdPaintOrder(
  List<ViHeapObject> drawable,
  Map<int, ViHeapObject> byId,
) => [...drawable]..sort((a, b) => _depthOf(a, byId).compareTo(_depthOf(b, byId)));

List<HeapRect> bdArrayShellWrapRects(ViDiagram diagram, int shellOid) {
  final children = diagram.children(shellOid).toList();
  bool contains(HeapRect outer, HeapRect inner) =>
      outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom;
  int largestContainerArea(HeapRect partBounds) {
    var bestArea = -1;
    for (final child in children) {
      final bounds = child.absBounds;
      if (child.objectClass != HeapObjectClass.controlChrome || bounds == null || !contains(bounds, partBounds)) {
        continue;
      }
      final area = bounds.width * bounds.height;
      if (area > bestArea) bestArea = area;
    }
    return bestArea;
  }

  return [
    for (final wrap in children)
      if (wrap.objectClass == HeapObjectClass.controlChrome && wrap.absBounds != null)
        if (!children.any(
              (other) =>
                  other.objectClass == HeapObjectClass.controlChrome &&
                  !identical(other, wrap) &&
                  other.absBounds != null &&
                  contains(other.absBounds!, wrap.absBounds!) &&
                  !contains(wrap.absBounds!, other.absBounds!),
            ) &&
            !children.any(
              (part) =>
                  part.objectClass == HeapObjectClass.numericControl &&
                  part.absBounds != null &&
                  contains(wrap.absBounds!, part.absBounds!) &&
                  wrap.absBounds!.width * wrap.absBounds!.height < largestContainerArea(part.absBounds!),
            ))
          wrap.absBounds!,
  ];
}

int _depthOf(ViHeapObject object, Map<int, ViHeapObject> byId) {
  var depth = 0;
  var cur = object;
  while (cur.parentOid != null && depth < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) break;
    cur = parent;
    depth++;
  }
  return depth;
}

const kSingleOpPrimClasses = {
  HeapObjectClass.bdNode3a,
  HeapObjectClass.bdNode34,
  HeapObjectClass.bdNode3e,
  HeapObjectClass.bdNode44,
  HeapObjectClass.bdNode6c,
  HeapObjectClass.bdNode93,
  HeapObjectClass.bdNode172,
  HeapObjectClass.bdNodeB9,
};

int? primIconKeyOf(ViHeapObject object) =>
    object.primResId ?? (kSingleOpPrimClasses.contains(object.objectClass) ? -object.kind : null);

int classVariantIconKey(int kind, int termCount) => -((kind << 8) | (termCount & 0xff)) - 0x100000;

const Set<int> kVerifiedBorderTerminalKinds = {
  0x22,
  0x2d,
  0x27,
  0x28,
  0x2e,
  0x2a,
  0xcb,
  0xce,
};

const int kTunnelHollowFlag = 0x1000000;

const int kTunnelCentreDotFlags = 0x300000;

Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})> bdBorderTerminalKinds(ViDiagram diagram) {
  final disabledOids = bdDisabledObjectOids(diagram);
  final out = <HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>{};
  final wires = bdVisibleWires(diagram);
  final dimsByTerminal = <int, Set<int>>{};
  for (final wire in wires) {
    final dims = wire.signalType?.arrayDims;
    if (dims == null) continue;
    for (var e = 0; e < wire.endpointOids.length; e++) {
      final attach = e < wire.endpointAttachRects.length ? wire.endpointAttachRects[e] : null;
      if (attach == null) continue;
      final terminal = diagram.endpointTerminal(wire.endpointOids[e]);
      if (terminal == null) continue;
      dimsByTerminal.putIfAbsent(terminal.oid, () => {}).add(dims);
    }
  }
  for (final wire in wires) {
    for (var e = 0; e < wire.endpointOids.length; e++) {
      final attach = e < wire.endpointAttachRects.length ? wire.endpointAttachRects[e] : null;
      if (attach == null) continue;
      final terminal = diagram.endpointTerminal(wire.endpointOids[e]);
      if (terminal != null && kVerifiedBorderTerminalKinds.contains(terminal.kind)) {
        out[attach] = (
          kind: terminal.kind,
          hollow:
              ((terminal.objFlags ?? 0) & kTunnelHollowFlag) != 0 || (dimsByTerminal[terminal.oid]?.length ?? 0) > 1,
          centreDot: ((terminal.objFlags ?? 0) & kTunnelCentreDotFlags) == kTunnelCentreDotFlags,
          disabled: disabledOids.contains(terminal.oid),
        );
      }
    }
  }
  return out;
}

Set<int> bdErrorCaseOids(ViDiagram diagram) => {
  for (final o in diagram.objects)
    if (o.objectClass == HeapObjectClass.bdStructureFrame &&
        diagram
            .children(o.oid)
            .any(
              (k) => k.objectClass == HeapObjectClass.bdSelectorLabel && k.label?.trim() == 'No Error',
            ))
      o.oid,
};

Set<int> bdDisabledObjectOids(ViDiagram diagram) {
  final out = <int>{};
  for (final o in diagram.objects) {
    if (o.objectClass != HeapObjectClass.bdDisableStructure) continue;
    final kids = diagram.children(o.oid).toList();
    final selector = kids.firstWhere((k) => k.objectClass == HeapObjectClass.bdSelectorLabel, orElse: () => o);
    if (identical(selector, o) || selector.label?.trim().toLowerCase() != 'disabled') {
      continue;
    }
    final shown = diagram.displayedFrameIndex(o);
    if (shown == null) continue;
    final stack = [diagram.framesOf(o)[shown].oid];
    while (stack.isNotEmpty) {
      final oid = stack.removeLast();
      for (final kid in diagram.children(oid)) {
        if (out.add(kid.oid)) stack.add(kid.oid);
      }
    }
  }
  return out;
}

class ViDiagramSemantics {
  ViDiagramSemantics(
    this.diagram, {
    List<ViWire>? wires,
    List<ViHeapObject>? drawable,
  }) : wires = wires ?? bdVisibleWires(diagram),
       drawable = drawable ?? bdDrawableObjects(diagram);

  final ViDiagram diagram;

  final List<ViHeapObject> drawable;

  final List<ViWire> wires;

  late final List<ViHeapObject> ordered = bdPaintOrder(drawable, diagram.byId);

  late final Set<int> disabledOids = bdDisabledObjectOids(diagram);

  late final Set<int> errorCaseOids = bdErrorCaseOids(diagram);

  late final Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})> borderTerminalKinds =
      bdBorderTerminalKinds(diagram);

  late final Map<int, List<({HeapRect box, int bmp})>> structureTerminals = bdStructureTerminals(diagram);

  late final Map<int, String> constValues = bdConstValueTexts(diagram);

  late final List<HeapRect> furnitureBounds = [
    for (final object in diagram.objects)
      if ((object.objectClass == HeapObjectClass.controlChrome ||
              object.objectClass == HeapObjectClass.numericDisplay) &&
          object.absBounds != null)
        object.absBounds!,
  ];
}
