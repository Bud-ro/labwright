/// Block-diagram **semantics** derived from a decoded [ViDiagram]: which
/// heap objects are real diagram content versus LabVIEW's internal
/// scaffolding, which structure frame is the displayed one, which dataflow
/// signals are live, what a constant's value reads as, and what a node's
/// label / operator / primitive identity is.
///
/// One layer above the heap decode and one below any renderer: everything
/// here is a function of decoded file data alone, expressed in this
/// package's own types ([ViDiagram], [ViHeapObject], [ViWire], [HeapRect]),
/// with no colours, canvases or pixel geometry. A renderer and a code
/// generator both read the same answers from here, so the drawn diagram and
/// anything derived from the diagram's logic cannot disagree about what the
/// file contains.
///
/// [ViDiagramSemantics] bundles the per-diagram results that a consumer
/// typically wants together, computing each lazily and once.
library;

import 'dart:math' show max, min;

import 'blocks/prim_ops.dart';
import 'graph.dart';
import 'heap.dart' show HeapRect;

/// Block-diagram node class codes that are **subVI call** nodes (they carry a
/// called-VI filename caption). LabVIEW draws these as a plain connector-pane
/// **icon plate** — commonly light grey — distinct from the pale-gold primitive
/// function nodes. Any node class not listed renders as a generic primitive
/// plate; the node's specific icon is not recovered, so it is never guessed.
///
/// `0x124` ([HeapObjectClass.bdNode124]) is here on its records rather than its
/// caption: it carries the same `OF__paramTableOffset` / `OF__connectorTM`
/// call-site fields, the same `0x33` parameter DCOs and the same connector-pane
/// terminal counts as `0x104`, and its holder count equals the named callee's
/// own `CPMp` width on every one of the 30 corpus nodes whose callee resolves.
const Set<int> kSubViCallNodeCodes = {0x31, 0x32, 0xc5, 0x104, 0x103, 0x8c, 0x124};

/// The short operator glyph drawn on a primitive node's plate for a decoded
/// [PrimOp] — the recognisable core of LabVIEW's icon art (the `+` of Add,
/// the type name of a conversion). Null for ops whose icon has no natural
/// short reading; the plate then stays blank rather than guessing art.
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

/// Per data-view terminal oid, the **numeric literal** its block-diagram
/// constant displays: the decoded value ([ViHeapObject.constNumeric]) lives on
/// the `0x13` bdConstDCO record, and the drawn box is that record's bounded
/// terminal child (crc8's oid 3033 shows `256` from its 0x13 parent's
/// record). Only decoded values map — a constant whose flattened value was
/// not recovered renders no text (never guessed). A whole-valued double
/// formats without the trailing `.0`, matching the integer rendering LabVIEW
/// gives whole values; stored per-constant display format specifiers are not
/// yet decoded (TODO).
Map<int, String> bdConstValueTexts(ViDiagram diagram) {
  final byId = diagram.byId;
  final out = <int, String>{};
  for (final object in diagram.objects) {
    if (object.category != ViObjectKind.terminal) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    final parent = byId[object.parentOid ?? -1];
    final value = parent?.kind == 0x13 ? parent!.constNumeric : null;
    if (value == null) continue;
    out[object.oid] = bdFormatConstValue(
      value,
      bdDisplayFormatOf(diagram, object.oid),
    );
  }
  return out;
}

/// The text a string constant's box DRAWS for its decoded value
/// ([ViHeapObject.constText]), trimmed of surrounding whitespace — or null
/// when the drawn form is not known.
///
/// The stored value is byte-exact, but a constant's DISPLAY MODE (normal,
/// `\`-codes, hex) is not decoded and decides how LabVIEW paints a byte
/// outside printable ASCII: `Config_Dump`'s `0x0A` constants draw the
/// two-glyph `\n` escape in a 27×19 box, not a line break, while the same
/// byte under the normal mode would break the line. A value carrying any such
/// byte therefore has no known drawn form and renders no text, rather than
/// painting the stored bytes as if they were glyphs.
String? bdDrawnConstText(ViHeapObject? object) {
  final text = object?.constText;
  if (text == null || text.codeUnits.any((code) => code < 0x20 || code >= 0x7f)) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The decoded printf-style display format of [oid]'s value window — the
/// `0xe0` display part's [ViHeapObject.displayFormat] — or null.
String? bdDisplayFormatOf(ViDiagram diagram, int oid) {
  for (final part in diagram.children(oid)) {
    if (part.kind == 0xe0 && part.displayFormat != null) {
      return part.displayFormat;
    }
  }
  return null;
}

/// The conversion letter of a `%`-led printf-style display [format] (`x` for
/// `%08x`, `f` for `%.0f`), or null when [format] is absent or unparsable.
String? bdFormatConversion(String? format) =>
    format == null ? null : RegExp(r'^%[-+ #0]*\d*(?:\.\d+)?([a-zA-Z])').firstMatch(format)?.group(1);

/// The digit text a constant box displays for [value] under its decoded
/// display [format] ([ViHeapObject.displayFormat]): the hex/octal/binary
/// conversions render the rounded integer in that radix (hex uppercase,
/// zero-padded to the format's field width under its `0` flag — MD5's `%08x`
/// initials read `67452301`); everything else keeps the decimal literal (a
/// whole-valued double without the trailing `.0`). The radix MARKER (the
/// small `x`/`b` glyph LabVIEW puts before the digits) is separate chrome
/// (a separate render fact), not part of this text. A negative integer's
/// radix rendering is width-dependent (two's complement at the stored type's
/// width) and falls back to decimal until reference-measured (TODO).
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

/// Class codes LabVIEW draws as **free text** on the canvas: the control
/// caption / free-label (`0x0a`) and the case-selector label (`0x95`). The
/// painter renders their recovered caption text within the label's own bounds,
/// backed by a bordered fill only when the label's background colour was
/// decoded (a comment's yellow backing) — never a guessed box.
const Set<int> kBdTextLabelCodes = {0x0a, 0x95};

/// The text to show on a node box: its recovered name when present (e.g. a subVI
/// filename), otherwise an honest class HINT derived from its classification
/// (`primitive`, `growable`, `Call Library node`) so the box isn't blank.
/// `isHint` is true for the class-derived fallback so it can be styled apart from
/// a real name. Pure + public for testing.
({String text, bool isHint}) nodeDisplayLabel(ViHeapObject object) {
  final label = object.label?.trim();
  if (label != null && label.isNotEmpty) return (text: label, isHint: false);
  final cls = object.objectClass.label;
  final match = RegExp(r'^Node \((.+)\)$').firstMatch(cls);
  return (text: match != null ? match.group(1)! : cls, isHint: true);
}

/// The badge text for a structure object — taken from the videcode CLASS CATALOG
/// ([HeapObjectClass.label]) rather than a hand-maintained table, so the inspector
/// can't drift from / contradict the catalog's honest, hedged names (e.g. 0x53 =
/// "Loop (BD) / container (FP)", 0x2c = "Case structure", 0x20 = "For loop").
/// Falls back to "Structure" only when the class is uncatalogued. Public for
/// testing + shared with the wireframe annotation.
String structureBadge(ViHeapObject object) =>
    object.objectClass == HeapObjectClass.unknown ? 'Structure' : object.objectClass.label;

/// The label drawn on a wireframe object. Structures (never text-labeled) show
/// their catalog kind via [structureBadge] (so the wireframe reads as logic too,
/// honestly tracking the class catalog — e.g. "For loop", "Case structure",
/// "Loop (BD) / container (FP)"); other objects show their recovered name and
/// (for terminals) data type. Pure + public for unit testing the canvas text.
String? wireframeAnnotation(ViHeapObject o) {
  if (o.category == ViObjectKind.structure) return structureBadge(o);
  final label = o.label;
  final type = o.typeKind == ViTypeKind.unknown ? null : o.typeKind.name;
  if (label != null && type != null) return '$label · $type';
  return label ?? type;
}

/// An honest, wire-free **control-flow outline** of a block diagram: the
/// structures grouped by catalog kind (e.g. `While loop`, `Case structure`), the
/// distinct **labeled-node captions** (a node's `C4 22` caption — for a subVI
/// usually its name, but NOT a proven call; many node kinds carry captions), and
/// the total node count. A text summary of the diagram's control-flow shape; it
/// lists no dataflow edges (those are drawn on the canvas from the decoded
/// signal endpoints). Pure + public so it is unit-testable.
({
  Map<String, int> structuresByKind,
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
  final byKind = <String, int>{};
  final labeledNodes = <String>[];
  var nodeCount = 0;
  final confidence = <ClassConfidence, int>{};
  for (final object in objects) {
    if (object.category == ViObjectKind.structure) {
      if (notControlFlow.contains(object.objectClass)) continue;
      final badge = structureBadge(object);
      byKind[badge] = (byKind[badge] ?? 0) + 1;
      confidence[object.objectClass.confidence] = (confidence[object.objectClass.confidence] ?? 0) + 1;
    } else if (object.category == ViObjectKind.node) {
      nodeCount++;
      confidence[object.objectClass.confidence] = (confidence[object.objectClass.confidence] ?? 0) + 1;
      final label = nodeDisplayLabel(object);
      if (!label.isHint && !labeledNodes.contains(label.text)) {
        labeledNodes.add(label.text);
      }
    }
  }
  return (
    structuresByKind: byKind,
    labeledNodes: labeledNodes,
    nodeCount: nodeCount,
    confidence: confidence,
  );
}

/// The control/indicator terminal classes that, when they appear as a **named**
/// leaf inside a block-diagram constant/structural subtree, are a called subVI's
/// own connector-pane controls spliced into the caller's heap (an inlined/
/// malleable subVI stores its panel controls here), NOT a top-level diagram
/// object LabVIEW draws. See [_isInlinedSubViControl].
const Set<int> _controlTerminalDrawCodes = {
  0x50,
  0x4f,
  0x57,
  0x5b,
  0x51,
  0x55,
  0x10c,
  0xc2,
  0x56,
};

/// Whether [o] is a **subVI connector-pane control spliced into this heap** by an
/// inlined/malleable subVI call — a control-terminal class ([_controlTerminalDrawCodes])
/// that (a) nests inside a block-diagram constant/structural subtree (a `0x13`
/// `bDConstDCO` or `0x15` structural record ancestor) and (b) carries a named,
/// **visible** `0x0a` caption child (the subVI control's drawn data name, e.g.
/// `Requirement ID`, `Label (VI Title)`). LabVIEW draws the subVI as a single
/// icon node, not its inlined internal controls, so these are not part of *this*
/// VI's top-level block diagram and are excluded from the drawn/fit set.
///
/// The caption child must be *visible* ([ViHeapObject.isLabelHidden] false): a
/// diagram constant carries its own `0x0a` name child too, but that name is
/// hidden by default (bit `0x08`), so LabVIEW paints only the constant box —
/// the constant stays in the drawn set. A bare unnamed constant terminal has no
/// caption child at all and is likewise kept. [childrenByOid] is the positional
/// child index.
bool _isInlinedSubViControl(
  ViHeapObject o,
  Map<int, ViHeapObject> byId,
  Map<int, List<ViHeapObject>> childrenByOid,
) {
  if (!_controlTerminalDrawCodes.contains(o.kind)) return false;
  var parentOid = o.parentOid;
  final seen = <int>{};
  var underConstOrStruct = false;
  while (parentOid != null && seen.add(parentOid)) {
    final parent = byId[parentOid];
    if (parent == null) break;
    if (parent.kind == 0x13 || parent.kind == 0x15) {
      // A `0x13` holder carrying a DECODED constant value is a real diagram
      // constant, visible caption or not — LabVIEW draws the constant box
      // with its name beside it (crc8's `bytes` / `8-bits` feeders). Only a
      // valueless const/struct wrapper marks a spliced subVI control. Gated
      // to the numeric-int terminals whose box chrome is reference-measured;
      // a named enum constant (FileReadOnly's `Read Only`) keeps the old
      // exclusion until its ring chrome is measured (TODO).
      if (parent.kind == 0x13 &&
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
    (c) => c.kind == 0x0a && !c.isLabelHidden && (c.label?.trim().isNotEmpty ?? false),
  );
}

/// Whether [o] is pure LabVIEW chrome that a faithful layout view should not
/// draw (corpus-validated; suppresses ~76% of raw heap objects, leaving real
/// structures, nodes, controls, decorations and caption bars):
/// - resize/scroll handles (`0x09`);
/// - content viewports (`0x11c`) — used only as the re-anchor frame, the
///   enclosing cluster/structure is drawn instead;
/// - hidden no-bounds terminals (`0x68`);
/// - the display/increment/terminal/item-list parts internal to a control
///   (`0xe0`/`0x0b`/`0x0c`/`0x0d` with a control-kind ancestor) — the control is
///   drawn as a single unit, not its internals (`0x0d`'s enum items are already
///   propagated up to the control, so suppressing it loses nothing);
/// - subVI-node internal display sub-parts (`0xe5`) — corpus: 947, all under a
///   `0xc5` node; they overlap the parent node and would otherwise paint a stray
///   unknown rectangle over it.
bool _isScaffolding(ViHeapObject o, Map<int, ViHeapObject> byId) {
  if (o.kind == 0x09 || o.kind == 0x11c) return true;
  if (o.kind == 0xe5) return true;
  if (o.kind == 0x68 && o.bounds == null) return true;
  if (o.kind == 0xe0 || o.kind == 0x0b || o.kind == 0x0c || o.kind == 0x0d) {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 64) {
      final parent = byId[parentOid];
      if (parent == null) break;
      if (kControlTerminalCodes.contains(parent.kind)) return true;
      parentOid = parent.parentOid;
      depth++;
    }
  }
  // ANYTHING nested inside a small bounded 0x53 CLUSTER container is the
  // container's internal machinery: LabVIEW draws the cluster box as one
  // unit — never the member shells, value windows, or labels
  // (Excel_Read_XLSX's StateData box at (316,826) — the reference shows the
  // single double-ringed box + glyph where the nested parts' own chrome
  // would otherwise clash).
  {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 8) {
      final parent = byId[parentOid];
      if (parent == null) break;
      if (parent.kind == 0x53 &&
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

/// The **drawn** objects [o] declares as members (childRef ∪ dcoRef from the
/// 0x14 ref graph), resolved via [byId] and filtered to objects actually on the
/// canvas (has bounds, not scaffolding-suppressed, not [o] itself) so a highlight
/// never floats over empty canvas. In practice members resolve to a drawn object
/// mostly for loops/structures — most other carriers' refs point at non-drawn
/// internal records — so the amber typically appears only for a selected structure.
/// Public for testing.
Set<ViHeapObject> membersOf(ViHeapObject? o, Map<int, ViHeapObject> byId) {
  if (o == null) return const {};
  return {
    for (final oid in o.memberOids)
      if (byId[oid] case final m? when m.absBounds != null && !identical(m, o) && !_isScaffolding(m, byId)) m,
  };
}

/// The **logic nodes/structures spatially inside** [structure] — the honest
/// "what this loop/case contains" signal (LabVIEW does not store an explicit
/// member list for the diagram, so containment is positional). Returns drawable
/// node/structure objects whose absolute bounds fall within [structure]'s bounds
/// (excluding itself and same-size overlaps); terminals/decorations are omitted
/// so the highlight reads as the contained logic. Public for testing.
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
    if (bounds.left == structureBounds.left &&
        bounds.top == structureBounds.top &&
        bounds.right == structureBounds.right &&
        bounds.bottom == structureBounds.bottom) {
      continue;
    }
    out.add(object);
  }
  return out;
}

/// The oids of every object inside a **hidden frame** of a stacked
/// multi-frame structure (a case/event structure holds one `0x1b` frame per
/// case, all at overlapping coordinates, but LabVIEW draws only the visible
/// one — drawing them all stacks every case's contents on top of each other).
///
/// For the stacked structure kinds ([kMultiFrameStructureKinds]) the decoded
/// [ViHeapObject.visibleFrameIndex] decides which frame draws. Elsewhere —
/// and for the rare out-of-range index — the content heuristic remains: the
/// frame with the most content positioned inside the structure's own box is
/// kept (the frames LabVIEW is not showing compose partly outside it or
/// hold less in-box content), and structures whose frames' in-box contents
/// are pairwise disjoint (a flat sequence tiling its frames side by side)
/// keep every frame. Pure + public for testing; shared by
/// [bdDrawableObjects] and [bdVisibleWires].
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
    final frames = (childrenByOid[structure.oid] ?? const <ViHeapObject>[]).where((c) => c.kind == 0x1b).toList();
    if (frames.length < 2) continue;

    // The stored display index decides outright for the stacked structure
    // kinds — including an absent record, which is render-verified to mean
    // frame 0. Out-of-range (one corpus outlier) falls through to the
    // content heuristic below. Flat sequences never reach here: they are a
    // different class (0xca) whose 0x121 subframes fail the 0x1b filter.
    if (kMultiFrameStructureKinds.contains(structure.kind)) {
      final visible = structure.visibleFrameIndex;
      if (visible < frames.length) {
        for (var i = 0; i < frames.length; i++) {
          if (i != visible) hideSubtree(frames[i]);
        }
        continue;
      }
    }

    // Per frame: how much positioned content sits inside the structure's box
    // (slack for tunnels/labels on the border), and that content's bbox.
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
      // One (or no) frame holds in-box content: LabVIEW shows exactly one
      // frame, so any other frame's content is not on this canvas.
      for (var i = 0; i < frames.length; i++) {
        if (candidates.isEmpty ? i > 0 : i != candidates.single) {
          hideSubtree(frames[i]);
        }
      }
      continue;
    }
    // Disjoint in-box contents = side-by-side frames (flat sequence): keep all.
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
    var visible = candidates.first;
    for (final i in candidates) {
      if (inBoxCounts[i] > inBoxCounts[visible]) visible = i;
    }
    for (var i = 0; i < frames.length; i++) {
      if (i != visible) hideSubtree(frames[i]);
    }
  }
  return hidden;
}

/// [diagram]'s dataflow wires prepared for drawing: signals living in a
/// hidden frame of a stacked multi-frame structure are dropped (a hidden
/// case's wires must not draw across the visible one, see
/// [bdHiddenFrameOids]), and an endpoint whose anchor did not resolve to a
/// positioned box (a structure tunnel — its border-crossing point carries no
/// decoded bounds) is re-anchored to its decoded attach rectangle when one
/// exists (the exact terminal square, [ViWire.endpointAttachRects]), else to
/// the endpoint's nearest drawable bounded ancestor, so the run reaches the
/// structure's border the way LabVIEW's tunnel wires do. A leg that only
/// resolves to the diagram root stays unanchored (drawing to the canvas edge
/// would be wrong), and a wire whose remaining anchors collapse onto one
/// identical box is dropped as degenerate.
List<ViWire> bdVisibleWires(ViDiagram diagram) {
  final hidden = bdHiddenFrameOids(diagram)..addAll(bdInlinedInstanceOids(diagram));
  final byId = diagram.byId;

  HeapRect? reanchor(int endpointOid) {
    var cur = byId[endpointOid];
    var depth = 0;
    while (cur != null && depth++ < 64) {
      final bounds = cur.absBounds;
      if (!hidden.contains(cur.oid) && bounds != null && bounds.width > 0 && bounds.height > 0) {
        // The diagram root's box is the whole canvas — not an anchor.
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
    // All legs on one identical box: nothing to route. (HeapRect has no
    // operator==, so compare edges.)
    final first = boxes.first;
    if (boxes.every(
      (b) => b.left == first.left && b.top == first.top && b.right == first.right && b.bottom == first.bottom,
    )) {
      continue;
    }
    out.add(
      patched
          ? ViWire(
              signalOid: wire.signalOid,
              endpointOids: wire.endpointOids,
              endpointAnchors: anchors,
              endpointAttachRects: wire.endpointAttachRects,
              // The stored route replays from endpoint 0's connection point:
              // it survives a re-anchored SINK (the route already targets the
              // border the sink was re-anchored to) but not a re-anchored
              // source, whose original connection point is what the lengths
              // measure from. The proven absolute polyline and the decoded
              // type word are independent of the anchor patch and ride along.
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

/// The oids of every object inside an **inlined sub-VI instance** (`0x105`):
/// an express/inlined call splices the called VI's whole internal diagram
/// into this heap under the instance node, in the sub-VI's own coordinate
/// space (its subtree re-bases toward the diagram origin). LabVIEW draws
/// only the instance node — which carries proper caller-space bounds — never
/// the internals, so the subtree is excluded from the drawable set and the
/// wire list.
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

/// Per structure oid, the **modeled structure terminals** of [diagram]: a
/// loop's iteration/count/conditional terminals, its shift registers, and a
/// case's selector tunnel — each with its decoded frame-relative box
/// ([ViHeapObject.termBounds]) and glyph selector ([ViHeapObject.termBmp]:
/// `i`→1, `N`→2, stop→192, shift registers→3/4, case selector→5). Terminals
/// without a decoded box are omitted (nothing is placed by guesswork), and a
/// terminal LabVIEW hides is dropped via the file's own per-terminal flag
/// ([ViDiagram.terminalGlyphHidden]: [kTerminalGlyphHiddenFlag] on the
/// terminal's DCO, render-verified on crc8's four loops — two drawn and two
/// hidden `i` glyphs, all four `N` glyphs drawn).
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
    // The owning structure: the nearest structure-category ancestor.
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

/// Whether [object]'s positional ancestry crosses a structure — node-glyph
/// art belongs to a node, and inside a structure frame it is never canvas
/// content.
bool _nestedInStructure(ViHeapObject object, Map<int, ViHeapObject> byId) {
  var cur = byId[object.parentOid ?? -1];
  var depth = 0;
  while (cur != null && depth++ < 16) {
    // The diagram root (0x7e, no parent) is not a structure for this test —
    // top-level glyphs are exactly the ones LabVIEW draws.
    if (cur.category == ViObjectKind.structure && cur.parentOid != null) {
      return true;
    }
    cur = byId[cur.parentOid ?? -1];
  }
  return false;
}

/// The **drawable** objects of [diagram] — the layout layer the BD/FP view and
/// the off-screen render oracle both paint: objects with a valid absolute
/// rectangle, excluding
/// the scaffolding parts ([_isScaffolding]), implausibly large boxes, and the
/// hidden frames of stacked multi-frame structures ([bdHiddenFrameOids]). Wires
/// (degenerate zero-area Manhattan runs) are kept via the wire exemption. Single
/// source of truth so the on-screen view and the off-screen oracle render the
/// same object set. Pure + public for the oracle and tests.
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
          // A node-glyph part (0x177) composed at negative coordinates is a
          // node's icon art in glyph space, not canvas space (crc8's floats
          // at (-8,-13) parented to the root frame) — drawing it stamps a
          // stray box and stretches the content extent. One nested inside a
          // structure frame is likewise suppressed — evidence so far is
          // crc8's single case (a 12x12 at (224,669) under a loop frame,
          // absent from the reference render); TODO: revisit if a corpus
          // reference ever shows a structure-nested 0x177 drawn. Top-level
          // positive-positioned 0x177s are real drawn glyphs (VI Tree's icon
          // row) and stay.
          !(object.kind == 0x177 &&
              (object.absBounds!.left < 0 || object.absBounds!.top < 0 || _nestedInStructure(object, byId))) &&
          !_escapesConstantBox(object, byId) &&
          !_escapesStructureBox(object, byId) &&
          // An owned name-label whose position was not composed lands glued to
          // the origin, extending upward (left == 0, bottom == 0) — 13 of the
          // snippet corpus's 1849 label parts, every one duplicating text that
          // belongs elsewhere. Drawing it stamps mislocated text AND inflates
          // the content rect above the diagram; labels anywhere else
          // (including legitimately negative coordinates) are kept.
          !(kBdTextLabelCodes.contains(object.kind) && object.absBounds!.left == 0 && object.absBounds!.bottom == 0) &&
          // An inlined/malleable subVI splices its own connector-pane controls
          // into this heap; LabVIEW draws the subVI as one icon node, not those
          // internal controls, so they are not this diagram's top-level content.
          !_isInlinedSubViControl(object, byId, childrenByOid) &&
          !_isScaffolding(object, byId))
        object,
  ];
}

/// Whether [object] is a constant's internal part composed **entirely outside
/// the constant's own box** — undrawable either way: LabVIEW clips a
/// constant's data view strictly to its box, so a part outside it is a
/// scrolled-out element or one whose coordinate frame the composition does
/// not yet decode (observed on cluster-in-cluster constants, whose whole
/// inner subtree re-bases near the diagram origin and wrecks the content
/// extent). The constant's box is the outermost bounded shell below the
/// `0x13` const-DCO record on [object]'s parent chain; the test is
/// **subtree-wide** — a part is undrawable when it, or ANY ancestor between
/// it and that shell, lies entirely outside the box (a part "inside" an
/// escaped ancestor is junk at a junk location). A free-text label is exempt
/// only when no ancestor escaped — a constant's own name label legitimately
/// hangs outside the box.
bool _escapesConstantBox(ViHeapObject object, Map<int, ViHeapObject> byId) {
  // Parent chain from [object] up to (exclusive) the 0x13 const-DCO record.
  final chain = <ViHeapObject>[];
  var cur = object;
  var depth = 0;
  var underConst = false;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) break;
    if (parent.kind == 0x13) {
      underConst = true;
      break;
    }
    chain.add(parent);
    cur = parent;
  }
  if (!underConst) return false;
  // Anchor: the outermost bounded shell just below the const record.
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
  if (kBdTextLabelCodes.contains(object.kind)) return false;
  final bounds = object.absBounds;
  return bounds != null && bounds.width > 0 && bounds.height > 0 && outside(bounds);
}

/// Whether [object] is composed **entirely outside** its nearest bounded
/// structure ancestor's box (inflated by [slack] px, so tunnels and owned
/// labels overhanging a border stay) — with **no wire (0x1d) on the chain**
/// between them: a wire-parented subtree legitimately escapes its heap
/// container (heap-nesting ≠ visual containment for wires), but a directly
/// nested part outside its frame is mis-composed (a coordinate frame the
/// origin composition does not yet decode) and drawing it stamps content at
/// junk positions and stretches the content extent. Free-text labels are
/// exempt.
bool _escapesStructureBox(
  ViHeapObject object,
  Map<int, ViHeapObject> byId, {
  int slack = 32,
}) {
  if (kBdTextLabelCodes.contains(object.kind)) return false;
  if (object.category == ViObjectKind.wire) return false;
  final bounds = object.absBounds;
  if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return false;
  var cur = object;
  var depth = 0;
  while (cur.parentOid != null && depth++ < 64) {
    final parent = byId[cur.parentOid];
    if (parent == null) return false;
    if (parent.kind == 0x1d) return false;
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

/// The `.vi`/`.vim` filenames [diagram]'s subVI-call nodes target — the wanted
/// set an icon resolver receives.
Set<String> subViWantedNames(ViDiagram diagram) => {
  for (final object in diagram.objects)
    if (kSubViCallNodeCodes.contains(object.kind))
      if (object.label?.trim() case final name? when name.isNotEmpty && _isViFileName(name)) name,
};

/// Whether [name] is a LabVIEW VI filename a subVI node targets (`.vi`/`.vim`).
bool _isViFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.vi') || lower.endsWith('.vim');
}

/// [drawable] sorted by nesting depth (shallowest first) — the paint order that
/// puts containers behind the nodes/controls they hold. Public for the oracle.
List<ViHeapObject> bdPaintOrder(
  List<ViHeapObject> drawable,
  Map<int, ViHeapObject> byId,
) => [...drawable]..sort((a, b) => _depthOf(a, byId).compareTo(_depthOf(b, byId)));

/// The drawn wrap frames of an array-constant shell (`0x52` [shellOid]):
/// the OUTERMOST bounded `0x9` parts (not strictly contained in a sibling
/// `0x9`), except that a `0x9` which contains a `0x50` part draws only when
/// it is that part's LARGEST container — a smaller container is a grid
/// window / row-column overlay zone whose edges the cell rings cover (MD5's
/// 1D grids hold an overlay zone straddling the element wrap's left wall:
/// outermost, but not the element's largest container, and drawing it leaks
/// a border corner below the index frame; crc8's index/element wraps
/// overlap each other by a column and both still draw).
///
/// Shared by the shell painter (each wrap is an opaque white fill + 1 px
/// border) and the wire container-face law: the wraps are the chrome a
/// wire's visible run stops against — the shell's own box edge is not
/// drawn ink.
List<HeapRect> bdArrayShellWrapRects(ViDiagram diagram, int shellOid) {
  final children = diagram.children(shellOid).toList();
  bool contains(HeapRect outer, HeapRect inner) =>
      outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom;
  int largestContainerArea(HeapRect partBounds) {
    var bestArea = -1;
    for (final child in children) {
      final bounds = child.absBounds;
      if (child.kind != 0x9 || bounds == null || !contains(bounds, partBounds)) {
        continue;
      }
      final area = bounds.width * bounds.height;
      if (area > bestArea) bestArea = area;
    }
    return bestArea;
  }

  return [
    for (final wrap in children)
      if (wrap.kind == 0x9 && wrap.absBounds != null)
        if (!children.any(
              (other) =>
                  other.kind == 0x9 &&
                  !identical(other, wrap) &&
                  other.absBounds != null &&
                  contains(other.absBounds!, wrap.absBounds!) &&
                  !contains(wrap.absBounds!, other.absBounds!),
            ) &&
            !children.any(
              (part) =>
                  part.kind == 0x50 &&
                  part.absBounds != null &&
                  contains(wrap.absBounds!, part.absBounds!) &&
                  wrap.absBounds!.width * wrap.absBounds!.height < largestContainerArea(part.absBounds!),
            ))
          wrap.absBounds!,
  ];
}

/// The nesting depth of [object] in the positional [byId] tree (root == 0),
/// capped so a malformed parent cycle cannot loop.
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

/// The primitive classes that ARE a single operation (no primResID record —
/// the class code is the identity); their icons are keyed as `-code`.
///
/// No class-icon assets are bundled (see assets/prim_icons/MANIFEST.md);
/// these nodes render as plain ringed plates. TODO(class-icons): re-extract
/// per-arity art. Reference facts measured on Excel_Read_XLSX for that
/// campaign: the 0x93 conversion node (oid 2714, 32x29) is a 0xFF444444
/// ring around 0xFFFFCC cream with black conversion art in the upper half
/// and its target-type text ("DBL") in the OUTPUT WIRE's datatype colour
/// (0xFF6600 float orange there — the current class147 extraction had baked
/// it grey); the 0x3a growable node's bottom-left cell shows TWO dotted
/// boxes, not one empty box (review feedback on oid 3007's class58 art).
const kSingleOpPrimClasses = {0x3a, 0x34, 0x3e, 0x44, 0x6c, 0x93, 0x172, 0xb9};

/// The icon-map key for [object]: its primResID when present, else the
/// negated class code for the single-op primitive classes, else null.
int? primIconKeyOf(ViHeapObject object) =>
    object.primResId ?? (kSingleOpPrimClasses.contains(object.kind) ? -object.kind : null);

/// The PER-ARITY icon key for a class-identified prim: several single-op
/// classes are growable stacked-terminal prims (0x3a/0x44 grow ~8px per
/// terminal), so one class carries one art PER TERMINAL COUNT — the
/// decoded identity, finer than the box size (0x44 renders t4 and t5 both
/// at 32x35). Encoded collision-free below the plain negated class codes.
/// Assets carry the arity in their name (`class58_t3.png`).
int classVariantIconKey(int kind, int termCount) => -((kind << 8) | (termCount & 0xff)) - 0x100000;

/// Terminal class codes whose border chrome is REFERENCE-VERIFIED (each
/// spec below was read from crc8/crc16/crc32 reference pixels at decoded
/// attach rects): plain loop tunnel `0x22` and select tunnel `0x2d` (a
/// wire-colour-filled square under a 1 px tunnel-border ring), left /
/// right shift registers `0x27`/`0x28` (2 px wire-colour border, cream
/// fill, wire-colour down-/up-arrow glyph), selector terminal `0x2e`
/// (1 px wire-colour border, cream fill, wire-colour `?` glyph); flat-
/// sequence border tunnels `0x2a`/`0xcb`, measured identical to the plain
/// tunnel square (Excel_Read_XLSX: one 0x2a and three 0xcb rects all read
/// the 1 px tunnel-border ring + solid wire-colour fill, punched
/// through the film-strip band); disable-structure border tunnels `0xce`,
/// same square (Excel_Read_XLSX oid 2228's path tunnel at (707,1043)).
/// Other border-terminal kinds stay undrawn until reference-verified.
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

/// The terminal [ViHeapObject.objFlags] bit marking a HOLLOW tunnel square
/// (cream interior with a wire-colour open ring — the same 5x5 art also
/// reads as the array-index brackets) instead of the solid wire-colour
/// fill. The ring has a SECOND trigger the flag does not carry: a tunnel
/// whose two sides' signals resolve DIFFERENT array dimensionalities (an
/// indexing tunnel — e.g. a 2D array outside, its 1D rows inside).
/// Snippet-corpus census over every wired 9x9 `0x22`/`0x2d` tunnel (721
/// terminal groups, 46 references): ring interior ⟺ this flag OR the
/// resolved dims differ, zero counterexamples — the flag-set rings all
/// index 0↔1 or carry an unresolved side, the flag-clear rings all index
/// 1↔2 or 2↔3, and the four flag-set solid-looking outliers of the earlier
/// flag-only census were dimmed rings under a disabled frame, not solids.
const int kTunnelHollowFlag = 0x1000000;

/// Tunnel-object flag bits whose BOTH-set form marks the tunnel that draws
/// the wire-fill square with a 3×3 WHITE centre carrying a wire-colour
/// centre dot (Excel_Read_XLSX's `Worksheets` case output tunnels at
/// (1721,905) and (1833,905): their `0x2d` terminals read 0x300801 where the
/// plain solid film tunnel reads 0x801). Measured on one VI — the two bits
/// never split there, so they are gated together (TODO: corpus-census which
/// bit carries the style, and the black-chevron tunnel variant beside it).
const int kTunnelCentreDotFlags = 0x300000;

/// Per decoded attach rect, its resolving terminal's class code, hollow
/// bit, and whether the terminal sits inside a disable structure's
/// displayed Disabled frame ([bdDisabledObjectOids] — its chrome then draws
/// through [dimDisabledFrameRgb]) — for the border-terminal chrome pass
/// (only [kVerifiedBorderTerminalKinds] draw).
Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})> bdBorderTerminalKinds(ViDiagram diagram) {
  final disabledOids = bdDisabledObjectOids(diagram);
  final out = <HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})>{};
  final wires = bdVisibleWires(diagram);
  // Resolved array dimensionalities of the signals each terminal joins —
  // an INDEXING tunnel (its sides resolve different dims) draws the hollow
  // ring even without [kTunnelHollowFlag] (see the flag's census law).
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

/// The oids of case structures whose DISPLAYED frame is the error-cluster
/// "No Error" case — LabVIEW draws their border band green with grey diagonal
/// stripes instead of the black case hatch. The signal is
/// the structure's own `0x95` selector label (the displayed frame's name),
/// byte-verified across the snippet corpus: every green-banded case frame
/// shows " No Error ", and no other selector value renders green (142 case
/// frames censused; the corpus holds no displayed "Error" frame, so that
/// variant stays undecoded).
Set<int> bdErrorCaseOids(ViDiagram diagram) => {
  for (final o in diagram.objects)
    if (o.kind == 0x2c && diagram.children(o.oid).any((k) => k.kind == 0x95 && k.label?.trim() == 'No Error')) o.oid,
};

/// The oids of drawable objects sitting under a disable structure's
/// DISPLAYED frame when that frame is a disabled one — LabVIEW renders their
/// icons as grey line-work on white. The
/// disabled-ness signal is the structure's own `0x95` selector label (the
/// displayed frame's name, e.g. " Disabled"): the label is drawn from the
/// file, never inferred from frame order.
Set<int> bdDisabledObjectOids(ViDiagram diagram) {
  final out = <int>{};
  for (final o in diagram.objects) {
    if (o.kind != 0xcd) continue;
    final kids = diagram.children(o.oid).toList();
    final selector = kids.firstWhere((k) => k.kind == 0x95, orElse: () => o);
    if (identical(selector, o) || selector.label?.trim().toLowerCase() != 'disabled') {
      continue;
    }
    final frames = kids.where((k) => k.kind == 0x1b).toList();
    final shown = o.visibleFrameIndex;
    if (shown >= frames.length) continue;
    final stack = [frames[shown].oid];
    while (stack.isNotEmpty) {
      final oid = stack.removeLast();
      for (final kid in diagram.children(oid)) {
        if (out.add(kid.oid)) stack.add(kid.oid);
      }
    }
  }
  return out;
}

/// Everything that derives purely from one [ViDiagram]'s block diagram —
/// the drawn object set, the live wires, and the per-object facts a renderer
/// or a code generator reads off them — computed once here and passed as a
/// unit, instead of each caller re-deriving and threading a parameter per
/// piece. Members are lazy, so a consumer that never looks at (say) the
/// wires never pays for their analysis.
class ViDiagramSemantics {
  ViDiagramSemantics(
    this.diagram, {
    List<ViWire>? wires,
    List<ViHeapObject>? drawable,
  }) : wires = wires ?? bdVisibleWires(diagram),
       drawable = drawable ?? bdDrawableObjects(diagram);

  /// The decoded diagram these semantics describe.
  final ViDiagram diagram;

  /// The drawn object set ([bdDrawableObjects]); callers may override (e.g.
  /// a probe rendering a subset).
  final List<ViHeapObject> drawable;

  /// The decoded dataflow wires ([bdVisibleWires], one per `0x17` signal),
  /// routed under the nodes/structures between their endpoint anchors; pass
  /// `const []` for a wire-free view.
  final List<ViWire> wires;

  /// [drawable] in painting order ([bdPaintOrder]).
  late final List<ViHeapObject> ordered = bdPaintOrder(drawable, diagram.byId);

  /// Objects under a disabled displayed frame ([bdDisabledObjectOids]).
  late final Set<int> disabledOids = bdDisabledObjectOids(diagram);

  /// Case structures displaying their "No Error" frame ([bdErrorCaseOids]).
  late final Set<int> errorCaseOids = bdErrorCaseOids(diagram);

  /// Attach rect → terminal class for reference-verified border-terminal
  /// chrome ([bdBorderTerminalKinds]).
  late final Map<HeapRect, ({int kind, bool hollow, bool centreDot, bool disabled})> borderTerminalKinds =
      bdBorderTerminalKinds(diagram);

  /// Per structure oid, its modeled terminals ([bdStructureTerminals]).
  late final Map<int, List<({HeapRect box, int bmp})>> structureTerminals = bdStructureTerminals(diagram);

  /// Per terminal oid, the numeric literal its constant box displays
  /// ([bdConstValueTexts]).
  late final Map<int, String> constValues = bdConstValueTexts(diagram);

  /// The display-part boxes of the whole heap — `0x9` decorations and `0xe0`
  /// value windows, in absolute diagram coordinates. Parts are not in
  /// [drawable], so this is the only pass that walks the heap for them; it
  /// depends on nothing but the diagram, so it is derived once here.
  late final List<HeapRect> furnitureBounds = [
    for (final object in diagram.objects)
      if ((object.kind == 0x9 || object.kind == 0xe0) && object.absBounds != null) object.absBounds!,
  ];
}
