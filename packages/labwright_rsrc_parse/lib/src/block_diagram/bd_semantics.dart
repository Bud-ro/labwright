/// What a block diagram shows: which objects and wires are drawn, in what order, with which
/// chrome, labels and constant texts; every function here reads a [BdDiagram] and returns the
/// decision, leaving the painting to the caller.
library;

import 'dart:math' show max, min;

import '../heap/heap.dart' show HeapRect;
import '../heap/heap_object.dart';
import '../heap/obj_flags.dart';
import '../heap/object_class.dart';
import 'bd_diagram.dart';
import 'bd_object.dart';
import 'prim_ops.dart';
import 'wire_route.dart';

/// Class codes of nodes that call a subVI by name.
const Set<int> kSubViCallNodeCodes = {0x31, 0x32, 0xc5, 0x104, 0x103, 0x8c, 0x124};

/// A short glyph drawn on a primitive's icon when no icon asset exists.
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

/// The text each numeric constant body displays, by body oid, formatted by the constant's
/// display format.
Map<int, String> bdConstValueTexts(BdDiagram diagram) {
  final out = <int, String>{};
  for (final body in diagram.controlBodies) {
    final bounds = body.absBounds;
    if (bounds.width <= 0 || bounds.height <= 0) continue;
    if (diagram.parentOf(body) case BdConstant(numeric: final value?)) {
      out[body.oid] = bdFormatConstValue(value, bdDisplayFormatOf(diagram, body.oid));
    }
  }
  return out;
}

// TODO: the constant display mode (normal, backslash codes, hex) is not decoded.
/// A string constant's text as drawn: trimmed, and only when every character is printable ASCII.
String? bdDrawnConstText(BdObject? object) {
  final text = object is BdConstant ? object.text : null;
  if (text == null || text.codeUnits.any((int code) => code < 0x20 || code >= 0x7f)) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The display format of the numeric display part under [oid].
String? bdDisplayFormatOf(BdDiagram diagram, int oid) {
  for (final part in diagram.children(oid)) {
    if (part case BdNumericDisplay(displayFormat: final format?)) return format;
  }
  return null;
}

/// The conversion character of a `%` format string.
String? bdFormatConversion(String? format) =>
    format == null ? null : RegExp(r'^%[-+ #0]*\d*(?:\.\d+)?([a-zA-Z])').firstMatch(format)?.group(1);

// TODO: negative integers under a radix format are not decoded; they fall back to decimal.
/// [value] rendered under [format]: hex, octal or binary with zero padding for the `x`, `o`
/// and `b` conversions, else decimal.
String bdFormatConstValue(num value, String? format) {
  final match = format == null ? null : RegExp(r'^%([-+ #0]*)(\d*)(?:\.\d+)?([a-zA-Z])').firstMatch(format);
  final radix = switch (match?.group(3)) {
    'x' || 'X' => 16,
    'o' => 8,
    'b' || 'B' => 2,
    _ => null,
  };
  final whole = value is double && value == value.roundToDouble() ? value.toInt() : value;
  if (match != null && radix != null && whole is int && whole >= 0) {
    var text = whole.toRadixString(radix).toUpperCase();
    final width = int.tryParse(match.group(2) ?? '') ?? 0;
    if (match.group(1)!.contains('0') && text.length < width) {
      text = text.padLeft(width, '0');
    }
    return text;
  }
  return whole.toString();
}

/// Classes drawn as text labels.
const Set<BdObjectClass> kBdTextLabelClasses = {
  BdObjectClass.textLabel,
  BdObjectClass.caseSelectorLabel,
};

/// A node's label, or its class name as a hint when it has none.
({String text, bool isHint}) nodeDisplayLabel(BdObject object) {
  final label = object.label?.trim();
  if (label != null && label.isNotEmpty) return (text: label, isHint: false);
  final cls = object.objectClass.label;
  final match = RegExp(r'^Node \((.+)\)$').firstMatch(cls);
  return (text: match != null ? match.group(1)! : cls, isHint: true);
}

/// The class name shown on a structure.
String structureBadge(BdObject object) => object.objectClass.isUnknown ? 'Structure' : object.objectClass.label;

/// The text a wireframe view annotates an object with: its badge, label and type kind.
String? wireframeAnnotation(BdObject o) {
  if (o.category == BdObjectKind.structure) return structureBadge(o);
  final label = o.label;
  final typeKind = o is HeapTypeBearer ? (o as HeapTypeBearer).typeKind : ViTypeKind.unknown;
  final type = typeKind == ViTypeKind.unknown ? null : typeKind.name;
  if (label != null && type != null) return '$label · $type';
  return label ?? type;
}

/// A summary of a diagram's structures and nodes: counts per structure class, the distinct
/// node labels, the node count and how many objects sit at each [ClassConfidence].
({
  Map<BdObjectClass, int> structuresByClass,
  List<String> labeledNodes,
  int nodeCount,
  Map<ClassConfidence, int> confidence,
})
computeBdOutline(Iterable<BdObject> objects) {
  final byClass = <BdObjectClass, int>{};
  final labeledNodes = <String>[];
  var nodeCount = 0;
  final confidence = <ClassConfidence, int>{};
  for (final object in objects) {
    final objectClass = object.objectClass;
    if (object.category == BdObjectKind.structure) {
      if (objectClass == BdObjectClass.root) continue;
      byClass[objectClass] = (byClass[objectClass] ?? 0) + 1;
    } else if (object.category == BdObjectKind.node) {
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

const Set<BdObjectClass> _controlTerminalDrawClasses = {
  BdObjectClass.numeric,
  BdObjectClass.boolean,
  BdObjectClass.enumRing,
  BdObjectClass.path,
  BdObjectClass.string,
  BdObjectClass.refnum,
  BdObjectClass.objectRefnum,
  BdObjectClass.variant,
  BdObjectClass.colorBox,
};

bool _isInlinedSubViControl(BdPlaced o, BdDiagram diagram) {
  if (o is! BdControlBody || !_controlTerminalDrawClasses.contains(o.objectClass)) return false;
  var underConstOrStruct = false;
  for (final parent in diagram.ancestorsOf(o)) {
    if (parent is BdConstant || parent is BdTerminalHolder) {
      if (parent case BdConstant(
        :final numeric,
        :final boolValue,
        :final text,
      ) when o.typeKind == ViTypeKind.numericInt && (numeric != null || boolValue != null || text != null)) {
        return false;
      }
      underConstOrStruct = true;
      break;
    }
  }
  if (!underConstOrStruct) return false;
  return diagram.childrenOf(o).any((c) => c is BdText && !c.isHidden && (c.label?.trim().isNotEmpty ?? false));
}

bool _isScaffolding(BdObject o, BdDiagram diagram) {
  if (o.objectClass == BdObjectClass.chrome || o is BdPane) return true;
  if (o.objectClass == BdObjectClass.polymorphicSelector) return true;
  if (o.objectClass == BdObjectClass.connectorTerminal && o is! BdPlaced) return true;
  if (o.objectClass == BdObjectClass.numericDisplay ||
      o.objectClass == BdObjectClass.controlPart ||
      o.objectClass == BdObjectClass.terminalCluster ||
      o.objectClass == BdObjectClass.itemList) {
    var depth = 0;
    for (final parent in diagram.ancestorsOf(o)) {
      if (depth++ >= 64) break;
      if (parent.objectClass.isControlTerminal) return true;
    }
  }
  var depth = 0;
  for (final parent in diagram.ancestorsOf(o)) {
    if (depth++ >= 8) break;
    if (parent case BdContainer(
      objectClass: BdObjectClass.cluster,
      absBounds: final bounds,
    ) when bounds.width <= 40 && bounds.height <= 24) {
      return true;
    }
  }
  return false;
}

/// The placed, non-scaffolding objects [o] refers to as members.
Set<BdPlaced> membersOf(BdObject? o, BdDiagram diagram) {
  if (o == null) return const {};
  return {
    for (final oid in o.memberOids)
      if (diagram.byOid(oid) case final BdPlaced m when !identical(m, o) && !_isScaffolding(m, diagram)) m,
  };
}

/// The nodes and structures whose bounds lie inside [structure]'s.
Set<BdPlaced> nodesWithin(BdPlaced structure, Iterable<BdPlaced> objects) {
  final structureBounds = structure.absBounds;
  final out = <BdPlaced>{};
  for (final object in objects) {
    if (identical(object, structure)) continue;
    if (object.category != BdObjectKind.node && object.category != BdObjectKind.structure) continue;
    final bounds = object.absBounds;
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

/// The objects not drawn: everything inside a hidden frame or an inlined instance.
Set<int> bdUndrawnOids(BdDiagram diagram) => bdHiddenFrameOids(diagram)..addAll(bdInlinedInstanceOids(diagram));

/// The oids under the frames a multi-frame structure does not show: the frames other than the
/// displayed one, or when the displayed index is unknown, the frames whose contents overlap the
/// fullest frame.
Set<int> bdHiddenFrameOids(BdDiagram diagram) {
  final hidden = <int>{};

  void hideSubtree(BdObject root) {
    hidden.add(root.oid);
    for (final child in diagram.childrenOf(root)) {
      hideSubtree(child);
    }
  }

  for (final structure in diagram.structures) {
    if (structure.category != BdObjectKind.structure) continue;
    final box = structure.absBounds;
    if (box.width <= 0 || box.height <= 0) continue;
    final frames = diagram.framesOf(structure);
    if (frames.length < 2) continue;

    final visible = structure is BdMultiFrameStructure ? diagram.displayedFrameIndex(structure) : null;
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
      void visit(BdObject o) {
        if (o case BdPlaced(absBounds: final bounds) when bounds.width > 0 && bounds.height > 0) {
          final cx = (bounds.left + bounds.right) / 2, cy = (bounds.top + bounds.bottom) / 2;
          if (cx >= box.left - 8 && cx <= box.right + 8 && cy >= box.top - 8 && cy <= box.bottom + 8) {
            count++;
            if (bounds.left < l) l = bounds.left;
            if (bounds.top < t) t = bounds.top;
            if (bounds.right > r) r = bounds.right;
            if (bounds.bottom > b) b = bounds.bottom;
          }
        }
        for (final child in diagram.childrenOf(o)) {
          visit(child);
        }
      }

      visit(frame);
      inBoxCounts.add(count);
      inBoxBoxes.add(count == 0 ? null : HeapRect(top: t, left: l, bottom: b, right: r));
    }
    final candidates = [
      for (var i = 0; i < frames.length; i++)
        if (inBoxBoxes[i] case final box?) (index: i, box: box),
    ];
    if (candidates.length < 2) {
      for (var i = 0; i < frames.length; i++) {
        if (candidates.isEmpty ? i > 0 : i != candidates.single.index) {
          hideSubtree(frames[i]);
        }
      }
      continue;
    }
    var overlapping = false;
    for (var i = 0; i < candidates.length && !overlapping; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        final one = candidates[i].box;
        final two = candidates[j].box;
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
    var fullest = candidates.first.index;
    for (final candidate in candidates) {
      if (inBoxCounts[candidate.index] > inBoxCounts[fullest]) fullest = candidate.index;
    }
    for (var i = 0; i < frames.length; i++) {
      if (i != fullest) hideSubtree(frames[i]);
    }
  }
  return hidden;
}

/// The wires drawn: those outside hidden frames and inlined instances, with missing anchors
/// re-based on the nearest visible placed ancestor, and at least two distinct anchors.
List<ViWire> bdVisibleWires(BdDiagram diagram, {Set<int>? undrawn}) {
  final hidden = undrawn ?? bdUndrawnOids(diagram);

  HeapRect? reanchor(int endpointOid) {
    var depth = 0;
    for (var cur = diagram.byOid(endpointOid); cur != null && depth++ < 64; cur = diagram.parentOf(cur)) {
      if (!hidden.contains(cur.oid) && cur is BdPlaced) {
        final bounds = cur.absBounds;
        if (bounds.width > 0 && bounds.height > 0) return cur.parentOid == null ? null : bounds;
      }
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

/// The oids under every XNode, whose contents are not drawn.
Set<int> bdInlinedInstanceOids(BdDiagram diagram) {
  final out = <int>{};
  void collect(BdObject root) {
    for (final child in diagram.childrenOf(root)) {
      if (out.add(child.oid)) collect(child);
    }
  }

  for (final object in diagram.nodes) {
    if (object.objectClass == BdObjectClass.xnode) collect(object);
  }
  return out;
}

/// Per structure oid, the terminal boxes on its border with the glyph each draws.
Map<int, List<({HeapRect box, int bmp})>> bdStructureTerminals(BdDiagram diagram) {
  final out = <int, List<({HeapRect box, int bmp})>>{};
  for (final terminal in diagram.terminals) {
    final box = terminal.termBounds;
    final bmp = terminal.termBmp;
    if (bmp == null || box.width <= 0 || box.height <= 0) continue;
    if (diagram.terminalGlyphHidden(terminal.oid)) continue;
    BdObject? owner;
    var depth = 0;
    for (final parent in diagram.ancestorsOf(terminal)) {
      if (parent.category == BdObjectKind.structure) {
        owner = parent;
        break;
      }
      if (depth++ >= 8) break;
    }
    if (owner == null) continue;
    (out[owner.oid] ??= []).add((box: box, bmp: bmp));
  }
  return out;
}

bool _nestedInStructure(BdObject object, BdDiagram diagram) {
  var depth = 0;
  for (final parent in diagram.ancestorsOf(object)) {
    if (depth++ >= 16) break;
    if (parent.category == BdObjectKind.structure && parent.parentOid != null) return true;
  }
  return false;
}

/// The objects drawn: placed, plausibly sized, outside hidden frames and inlined instances,
/// inside their constant and structure boxes, and neither scaffolding nor an inlined subVI
/// control.
List<BdPlaced> bdDrawableObjects(BdDiagram diagram, {Set<int>? undrawn}) {
  final hidden = undrawn ?? bdUndrawnOids(diagram);
  return [
    for (final object in diagram.placed)
      if (object.absBounds case final bounds
          when bounds.isValid &&
              (object is BdWire || (bounds.width > 0 && bounds.height > 0)) &&
              bounds.width < 8000 &&
              bounds.height < 8000 &&
              !hidden.contains(object.oid) &&
              !(object.objectClass == BdObjectClass.attachmentArrow &&
                  (bounds.left < 0 || bounds.top < 0 || _nestedInStructure(object, diagram))) &&
              !_escapesConstantBox(object, diagram) &&
              !_escapesStructureBox(object, diagram) &&
              !(object is BdText && bounds.left == 0 && bounds.bottom == 0) &&
              !_isInlinedSubViControl(object, diagram) &&
              !_isScaffolding(object, diagram))
        object,
  ];
}

bool _escapesConstantBox(BdPlaced object, BdDiagram diagram) {
  final chain = <BdObject>[];
  var underConst = false;
  var depth = 0;
  for (final parent in diagram.ancestorsOf(object)) {
    if (depth++ >= 64) break;
    if (parent is BdConstant) {
      underConst = true;
      break;
    }
    chain.add(parent);
  }
  if (!underConst) return false;
  HeapRect? anchor;
  for (final shell in chain.reversed) {
    if (shell case BdPlaced(absBounds: final bounds) when bounds.width > 0 && bounds.height > 0) {
      anchor = bounds;
      break;
    }
  }
  final box = anchor;
  if (box == null) return false;
  bool outside(HeapRect b) => b.right <= box.left || b.left >= box.right || b.bottom <= box.top || b.top >= box.bottom;
  for (final ancestor in chain) {
    if (ancestor case BdPlaced(absBounds: final bounds) when bounds.width > 0 && bounds.height > 0) {
      if (identical(bounds, box)) continue;
      if (outside(bounds)) return true;
    }
  }
  if (object is BdText) return false;
  final bounds = object.absBounds;
  return bounds.width > 0 && bounds.height > 0 && outside(bounds);
}

bool _escapesStructureBox(BdPlaced object, BdDiagram diagram, {int slack = 32}) {
  if (object is BdText || object is BdWire) return false;
  final bounds = object.absBounds;
  if (bounds.width <= 0 || bounds.height <= 0) return false;
  var depth = 0;
  for (final parent in diagram.ancestorsOf(object)) {
    if (depth++ >= 64) break;
    if (parent is BdWire) return false;
    if (parent case BdPlaced(
      absBounds: final box,
      category: BdObjectKind.structure,
    ) when box.width > 0 && box.height > 0) {
      return bounds.right <= box.left - slack ||
          bounds.left >= box.right + slack ||
          bounds.bottom <= box.top - slack ||
          bounds.top >= box.bottom + slack;
    }
  }
  return false;
}

/// The VI file names the diagram's subVI call nodes are labelled with.
Set<String> subViWantedNames(BdDiagram diagram) => {
  for (final node in diagram.nodes)
    if (kSubViCallNodeCodes.contains(node.kind))
      if (node.label?.trim() case final name? when name.isNotEmpty && _isViFileName(name)) name,
};

bool _isViFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.vi') || lower.endsWith('.vim');
}

/// [drawable] sorted shallowest first, so containers paint under their contents.
List<BdPlaced> bdPaintOrder(List<BdPlaced> drawable, BdDiagram diagram) =>
    [...drawable]..sort((a, b) => diagram.depthOf(a).compareTo(diagram.depthOf(b)));

/// The outermost chrome boxes of an array shell that wrap its elements, excluding chrome that
/// sits inside a larger box around the same numeric part.
List<HeapRect> bdArrayShellWrapRects(BdDiagram diagram, int shellOid) {
  final children = diagram.children(shellOid);
  final chrome = [
    for (final child in children)
      if (child case BdPart(objectClass: BdObjectClass.chrome, :final absBounds)) absBounds,
  ];
  final numericParts = [
    for (final child in children)
      if (child case BdControlBody(objectClass: BdObjectClass.numeric, :final absBounds)) absBounds,
  ];
  bool contains(HeapRect outer, HeapRect inner) =>
      outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom;
  int largestContainerArea(HeapRect partBounds) {
    var bestArea = -1;
    for (final bounds in chrome) {
      if (!contains(bounds, partBounds)) continue;
      final area = bounds.width * bounds.height;
      if (area > bestArea) bestArea = area;
    }
    return bestArea;
  }

  return [
    for (final wrapBounds in chrome)
      if (!chrome.any(
            (otherBounds) =>
                !identical(otherBounds, wrapBounds) &&
                contains(otherBounds, wrapBounds) &&
                !contains(wrapBounds, otherBounds),
          ) &&
          !numericParts.any(
            (partBounds) =>
                contains(wrapBounds, partBounds) &&
                wrapBounds.width * wrapBounds.height < largestContainerArea(partBounds),
          ))
        wrapBounds,
  ];
}

/// Node classes that each stand for one primitive and so key their icon by class code.
const kSingleOpPrimClasses = {
  BdObjectClass.buildArray,
  BdObjectClass.bundle,
  BdObjectClass.concatenateStrings,
  BdObjectClass.indexArray,
  BdObjectClass.compoundArithmetic,
  BdObjectClass.formatIntoString,
  BdObjectClass.mergeErrors,
  BdObjectClass.replaceArraySubset,
};

/// The icon key of a node: its `primResID`, or the negated class code for a single-op class.
int? primIconKeyOf(BdObject object) => switch (object) {
  BdPrimitive(:final primResId) => primResId,
  _ when kSingleOpPrimClasses.contains(object.objectClass) => -object.kind,
  _ => null,
};

/// The icon key of a class variant with [termCount] terminals, distinct from any `primResID`
/// and any single-op class key.
int classVariantIconKey(int kind, int termCount) => -((kind << 8) | (termCount & 0xff)) - 0x100000;

/// The asset name of a prim icon key: `prim<id>` for a primResID, `class<code>` for a
/// single-op class, `class<code>_t<n>` for a class variant with `n` terminals.
String primIconName(int key) {
  if (key >= 0) return 'prim$key';
  if (key > -0x100000) return 'class${-key}';
  final packed = -(key + 0x100000);
  return 'class${packed >> 8}_t${packed & 0xff}';
}

/// The prim icon key spelled by [name], or null when it is not one; the inverse of [primIconName].
int? parsePrimIconName(String name) {
  final match = RegExp(r'^(prim|class)(\d+)(?:_t(\d+))?$').firstMatch(name);
  if (match == null) return null;
  final number = int.parse(match.group(2)!);
  if (match.group(1) == 'prim') return number;
  final terms = match.group(3);
  return terms == null ? -number : classVariantIconKey(number, int.parse(terms));
}

/// Border terminals drawn as tunnel squares.
const Set<BdObjectClass> kBdTunnelClasses = {
  BdObjectClass.loopTunnel,
  BdObjectClass.caseTunnel,
  BdObjectClass.sequenceTunnel,
  BdObjectClass.sequenceFrameTunnel,
  BdObjectClass.disableTunnel,
};

/// The left and right shift register classes.
const Set<BdObjectClass> kBdShiftRegisterClasses = {
  BdObjectClass.leftShiftRegister,
  BdObjectClass.rightShiftRegister,
};

/// Border terminals whose chrome is established: tunnels, shift registers and the case selector.
const Set<BdObjectClass> kBdBorderTerminalClasses = {
  ...kBdTunnelClasses,
  ...kBdShiftRegisterClasses,
  BdObjectClass.caseSelectorTerminal,
};

/// How a border terminal is drawn: its class, hollow when flagged or wired at more than one array
/// depth, with a centre dot when flagged, dimmed when inside a disabled frame.
typedef BdBorderTerminal = ({BdObjectClass objectClass, bool hollow, bool centreDot, bool disabled});

/// The chrome of every border terminal a visible wire attaches to, by attach box.
Map<HeapRect, BdBorderTerminal> bdBorderTerminalKinds(BdDiagram diagram, {Set<int>? disabledOids}) {
  disabledOids ??= bdDisabledObjectOids(diagram);
  final out = <HeapRect, BdBorderTerminal>{};
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
      if (terminal != null && kBdBorderTerminalClasses.contains(terminal.objectClass)) {
        out[attach] = (
          objectClass: terminal.objectClass,
          hollow: terminal.hasFlag(ViObjFlag.tunnelHollow) || (dimsByTerminal[terminal.oid]?.length ?? 0) > 1,
          centreDot: terminal.hasFlag(ViObjFlag.tunnelCentreDot),
          disabled: disabledOids.contains(terminal.oid),
        );
      }
    }
  }
  return out;
}

/// Case structures whose selector label reads `No Error`, drawn with the error-case chrome.
Set<int> bdErrorCaseOids(BdDiagram diagram) => {
  for (final o in diagram.structures)
    if (o is BdCaseStructure && diagram.childrenOf(o).any((k) => _selectorLabelOf(k) == 'No Error')) o.oid,
};

String? _selectorLabelOf(BdObject object) =>
    object is BdText && object.objectClass == BdObjectClass.caseSelectorLabel ? object.label?.trim() : null;

/// The oids inside the shown frame of every disable structure whose selector reads `Disabled`.
Set<int> bdDisabledObjectOids(BdDiagram diagram) {
  final out = <int>{};
  for (final o in diagram.structures) {
    if (o is! BdMultiFrameStructure || o.objectClass != BdObjectClass.disableStructure) continue;
    final selector = diagram.childrenOf(o).map(_selectorLabelOf).whereType<String>().firstOrNull;
    if (selector?.toLowerCase() != 'disabled') continue;
    final shown = diagram.displayedFrameIndex(o);
    if (shown == null) continue;
    final stack = <BdObject>[diagram.framesOf(o)[shown]];
    while (stack.isNotEmpty) {
      for (final kid in diagram.childrenOf(stack.removeLast())) {
        if (out.add(kid.oid)) stack.add(kid);
      }
    }
  }
  return out;
}

/// The drawing decisions for one diagram, each computed once on first use.
class ViDiagramSemantics {
  factory ViDiagramSemantics(BdDiagram diagram, {List<ViWire>? wires, List<BdPlaced>? drawable}) {
    final undrawn = wires == null || drawable == null ? bdUndrawnOids(diagram) : null;
    return ViDiagramSemantics._(
      diagram,
      wires ?? bdVisibleWires(diagram, undrawn: undrawn),
      drawable ?? bdDrawableObjects(diagram, undrawn: undrawn),
    );
  }

  ViDiagramSemantics._(this.diagram, this.wires, this.drawable);

  final BdDiagram diagram;

  final List<BdPlaced> drawable;

  final List<ViWire> wires;

  /// [drawable] in paint order.
  late final List<BdPlaced> ordered = bdPaintOrder(drawable, diagram);

  late final Set<int> disabledOids = bdDisabledObjectOids(diagram);

  late final Set<int> errorCaseOids = bdErrorCaseOids(diagram);

  late final Map<HeapRect, BdBorderTerminal> borderTerminalKinds = bdBorderTerminalKinds(
    diagram,
    disabledOids: disabledOids,
  );

  late final Map<int, List<({HeapRect box, int bmp})>> structureTerminals = bdStructureTerminals(diagram);

  late final Map<int, String> constValues = bdConstValueTexts(diagram);

  /// The boxes of chrome and numeric display parts, drawn as furniture.
  late final List<HeapRect> furnitureBounds = [
    for (final object in diagram.placed)
      if (object.objectClass == BdObjectClass.chrome || object is BdNumericDisplay) object.absBounds,
  ];
}
