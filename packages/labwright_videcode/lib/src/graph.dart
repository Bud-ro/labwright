import 'dart:typed_data';

import 'heap.dart';

/// The structural category of a heap object, from its class code + signals
/// (corpus-validated). Coarse but honest — node-vs-subVI and control-vs-indicator
/// are not separable from `BDEx` alone, so they are not distinguished.
enum ViObjectKind {
  /// A node's terminal/connector cluster (class `0x0c`; carries `C4 1F` terminals).
  terminalCluster,

  /// A terminal — a node connection point or a control/indicator terminal
  /// (classes `0x68`, `0x50/51/57/4f/5b`, `0x0a/0b/0d/e0`).
  terminal,

  /// A function / subVI node body (class `0x12`).
  node,

  /// A structure (loop/case/sequence) or a diagram container/frame
  /// (classes `0x53/52`, the root `0x7e`, `0x4c`, `0x11c`, `0x09`).
  structure,

  /// A decoration (unlabeled, never-wired large rect).
  decoration,

  /// Not classifiable from the available signals.
  unknown,
}

/// The inferred data-type kind of an object, from its attached `C4` records.
/// Payload-grounded; bool/string/array/cluster are not payload-encoded.
enum ViTypeKind {
  /// Integer numeric (a `C4 74` format string with a `b`/`d`/`o`/`x`/`X` conv).
  numericInt,

  /// Floating-point numeric (a `C4 74` format with an `e`/`f`/`g`/`p` conv).
  numericFloat,

  /// Enum / ring control (a `C4 2E` item list).
  enumRing,

  /// A filesystem/library path (`C4 A4` `PTH0`).
  path,

  /// A Call-Library node (`C4 C4` symbol + `C4 A4` library path).
  clnNode,

  /// No data-type signal present.
  unknown,
}

/// One object in a block-diagram heap, recovered by [buildDiagram].
///
/// The heap is a **balanced typed-group tree**: an object opens with
/// `10/11/12 <tag> 02 fe <u16 kind> fd <u16 oid>` and the tree is delimited by
/// high-nibble-1 group opens (`10/11/12/13 <tag>` where the byte after the count
/// is a type tag `FB`/`FE`/`FD`) and high-nibble-0 closes (`08/09/0a/0b`, popped
/// positionally). `oid` is unique within a VI. Records attach to the innermost
/// object: `C4 2D` → [bounds]/[absBounds], `C4 22` → [label],
/// `14 19 01 fd <id>` → [refs] (child-membership ids, found on structure/diagram
/// container objects).
class ViHeapObject {
  ViHeapObject({required this.oid, required this.kind, required this.offset});

  /// The object's unique id (the `oid` field of its header).
  final int oid;

  /// The object's class code (the `kind` field of its header). `0x68` = terminal;
  /// `0x53`/`0x4c` = structure/diagram container; `0x12` = node; `0x0c` = terminal
  /// cluster.
  final int kind;

  /// Byte offset of the object's header within the heap body.
  final int offset;

  /// The object's bounding rectangle in **container-local** coordinates (from a
  /// `C4 2D` record), or null.
  HeapRect? bounds;

  /// The object's bounding rectangle in **absolute diagram coordinates**
  /// (recursively offset by its object-ancestors' origins), or null. Scrolled-
  /// cluster control terminals are re-anchored to their `0x11c` content viewport
  /// (see [_reanchorScrolledControls]). Validated: terminals fall inside their
  /// parent node/viewport ~99–100%.
  HeapRect? absBounds;

  /// The `oid` of this object's parent object in the nesting tree, or null for the
  /// diagram root.
  int? parentOid;

  /// The object's label/caption (from a `C4 22` record), or null.
  String? label;

  /// Child-membership object-id references (from `14 19 01 fd <id>` records, the
  /// `10 55 01 fb` reflist) — populated on structure/diagram container objects;
  /// these are the oids the container holds, **not** wire endpoints.
  final List<int> refs = <int>[];

  /// Number of `C4 1F` terminal records attached.
  int termCount = 0;

  /// Structural category (set during [buildDiagram]). See [ViObjectKind].
  ViObjectKind category = ViObjectKind.unknown;

  /// Inferred data-type kind from attached `C4` records. See [ViTypeKind].
  ViTypeKind typeKind = ViTypeKind.unknown;
}

/// Classifies a heap object into a [ViObjectKind] from its class code and signals
/// (corpus-validated; see `docs/vi-rsrc-and-heap-format.md`).
ViObjectKind classifyObject({required int kind, required bool hasBounds, required int termCount}) {
  if (kind == 0x0c || termCount >= 1) return ViObjectKind.terminalCluster;
  if (kind == 0x12) return ViObjectKind.node;
  const structures = {0x53, 0x52, 0x09, 0x7e, 0x4c, 0x11c};
  if (structures.contains(kind)) return ViObjectKind.structure;
  const terminals = {0x68, 0x50, 0x51, 0x57, 0x4f, 0x5b, 0xdf, 0x0a, 0x0b, 0x0d, 0xe0};
  if (terminals.contains(kind)) return ViObjectKind.terminal;
  const decorations = {0x8f, 0xe7, 0xd2, 0xc7, 0xc8};
  if (decorations.contains(kind)) return ViObjectKind.decoration;
  return ViObjectKind.unknown;
}

/// The printf conversion char of a `C4 74` numeric format-string payload, or null.
int? _formatConvChar(List<int> payload) {
  var seenPercent = false;
  for (final c in payload) {
    if (!seenPercent) {
      if (c == 0x25) seenPercent = true; // '%'
      continue;
    }
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) return c;
  }
  return null;
}

/// Infers a [ViTypeKind] from the set of `C4` opcodes attached to an object plus
/// the numeric format payload (if any). Payload-grounded.
ViTypeKind inferTypeKind(Set<int> c4ops, List<int>? formatPayload) {
  if (c4ops.contains(0xc4)) return ViTypeKind.clnNode;
  if (c4ops.contains(0xa4)) return ViTypeKind.path;
  if (c4ops.contains(0x2e)) return ViTypeKind.enumRing;
  if (c4ops.contains(0x74)) {
    final conv = formatPayload == null ? null : _formatConvChar(formatPayload);
    const intConvs = {0x62, 0x64, 0x6f, 0x78, 0x58}; // b d o x X
    return (conv != null && intConvs.contains(conv)) ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
  }
  return ViTypeKind.unknown;
}

/// A recovered block-diagram (or other heap) as a **nesting tree** of
/// [ViHeapObject]s with absolute coordinates. The `14 19 01 fd` references are
/// child-membership (structure → contained oids), **not** signal wires: actual
/// dataflow wires are stored as geometry (no oid endpoints) and so do not appear
/// as resolvable edges here. Partial/honest: object class codes and wire
/// direction are not fully decoded.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects});

  /// The section this diagram came from (`BDEx` = block diagram).
  final String sectionTag;

  /// All recovered objects, in heap (pre-order) order.
  final List<ViHeapObject> objects;

  /// Objects indexed by their unique [ViHeapObject.oid].
  Map<int, ViHeapObject> get byId => {for (final o in objects) o.oid: o};

  /// The root object(s) of the nesting tree (parentOid == null) — normally the
  /// single diagram root (kind `0x7e`).
  Iterable<ViHeapObject> get roots => objects.where((o) => o.parentOid == null);

  /// The direct children of the object with [oid] in the nesting tree.
  Iterable<ViHeapObject> children(int oid) => objects.where((o) => o.parentOid == oid);

  /// The bounded objects (have an absolute rectangle) — the drawable layout layer.
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.absBounds != null);
}

bool _isTypeTag(int b) => b == 0xfb || b == 0xfe || b == 0xfd;

/// Recovers the [ViDiagram] from a decompressed heap [body] by walking its record
/// stream ([walkHeapBody]) as a **balanced typed-group tree**: a group opens at a
/// high-nibble-1 opcode (`10/11/12/13 <tag>` with a type tag after the count) and
/// closes at a high-nibble-0 opcode (`08/09/0a/0b`, popped positionally). Object
/// headers (`10/11/12 <tag> 02 fe <kind> fd <oid>`) become [ViHeapObject]s
/// parented by the enclosing object; `C4 2D`/`C4 22`/`14 19 01 fd` records attach
/// to the innermost object; absolute coordinates compose down the object-ancestor
/// chain. Total/bounds-safe.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDEx'}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final fmt = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  // Group stack: each entry is (object-or-null, isObject). Non-object groups
  // (typed lists like `10 55 01 fb`) are pushed too, so closes balance.
  final stack = <ViHeapObject?>[];
  final n = body.length;

  ViHeapObject? innermostObject() {
    for (var k = stack.length - 1; k >= 0; k--) {
      if (stack[k] != null) return stack[k];
    }
    return null;
  }

  for (final s in walkHeapBody(body).spans) {
    final o = s.offset;
    final lead = s.lead;
    final isGroupOpen = (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) &&
        o + 4 <= n &&
        _isTypeTag(body[o + 3]);
    if (isGroupOpen) {
      final isObj = (lead == 0x10 || lead == 0x11 || lead == 0x12) &&
          o + 9 <= n &&
          body[o + 2] == 0x02 &&
          body[o + 3] == 0xfe &&
          body[o + 6] == 0xfd;
      if (isObj) {
        final cur = ViHeapObject(
          oid: (body[o + 7] << 8) | body[o + 8],
          kind: (body[o + 4] << 8) | body[o + 5],
          offset: o,
        );
        final parent = innermostObject();
        cur.parentOid = parent?.oid;
        // absolute origin starts at the parent object's origin (pass-through).
        absTop[cur] = parent == null ? 0 : (absTop[parent] ?? 0);
        absLeft[cur] = parent == null ? 0 : (absLeft[parent] ?? 0);
        objects.add(cur);
        c4ops[cur] = <int>{};
        stack.add(cur);
      } else {
        stack.add(null);
      }
      continue;
    }
    if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    final cur = innermostObject();
    if (cur == null) continue;
    if (lead == kHeapRecordPrefix) {
      final rec = c4FrameAt(body, o, sectionTag);
      if (rec == null) continue;
      c4ops[cur]!.add(rec.opcode);
      if (rec.opcode == 0x2d) {
        if (cur.bounds == null) {
          cur.bounds = rec.bounds;
          if (cur.bounds != null) {
            absTop[cur] = (absTop[cur] ?? 0) + cur.bounds!.top;
            absLeft[cur] = (absLeft[cur] ?? 0) + cur.bounds!.left;
            cur.absBounds = HeapRect(
              top: absTop[cur]!,
              left: absLeft[cur]!,
              bottom: absTop[cur]! + cur.bounds!.height,
              right: absLeft[cur]! + cur.bounds!.width,
            );
          }
        }
      } else if (rec.opcode == 0x22) {
        cur.label ??= rec.text;
      } else if (rec.opcode == 0x1f) {
        cur.termCount++;
      } else if (rec.opcode == 0x74) {
        fmt[cur] ??= rec.payload;
      }
    } else if (lead == 0x14 && o + 6 <= n && body[o + 1] == 0x19 && body[o + 2] == 0x01 && body[o + 3] == 0xfd) {
      cur.refs.add((body[o + 4] << 8) | body[o + 5]);
    }
  }

  for (final o in objects) {
    o.category = classifyObject(kind: o.kind, hasBounds: o.bounds != null, termCount: o.termCount);
    o.typeKind = inferTypeKind(c4ops[o] ?? const <int>{}, fmt[o]);
  }

  _reanchorScrolledControls(objects);
  return ViDiagram(sectionTag: sectionTag, objects: objects);
}

/// Control-terminal classes (front-panel control/indicator terminals).
const _controlKinds = {0x50, 0x4f, 0x57, 0x5b, 0x51};

/// Re-anchors **scrolled-cluster control terminals** to their content viewport.
///
/// A control terminal nested under a `0x11c` content viewport stores its bounds
/// in the viewport's *scrolled content* coordinate frame (tops are typically
/// large-negative), so composing absolute coordinates down the ancestor chain
/// detaches the control — it floats far above its own cluster. The fix: re-anchor
/// every such control to its viewport's absolute origin, using the **min corner
/// of the control group sharing that viewport** as the content origin (an
/// overlap-safe equivalent of the unstored scroll origin — each group's source
/// coordinates are internally non-overlapping, so a pure group translation
/// preserves that). The whole control subtree (label, sub-terminals) is shifted
/// by the same delta so it stays intact.
///
/// Control terminals **not** under a `0x11c` (direct on-diagram terminals) are
/// already in correct absolute coordinates and are left untouched. Corpus-
/// validated across 398 BDEx sections: control↔control overlap 6.5% → 0.35%,
/// re-anchored-control-center-inside-its-viewport 12% → 99%.
void _reanchorScrolledControls(List<ViHeapObject> objects) {
  final byOid = {for (final o in objects) o.oid: o};
  final kids = <int, List<ViHeapObject>>{};
  for (final o in objects) {
    if (o.parentOid != null) (kids[o.parentOid!] ??= <ViHeapObject>[]).add(o);
  }

  int? nearestViewport(ViHeapObject o) {
    var p = o.parentOid;
    while (p != null) {
      final po = byOid[p];
      if (po == null) return null;
      if (po.kind == 0x11c) return po.oid;
      p = po.parentOid;
    }
    return null;
  }

  // Group re-anchorable controls by the viewport that owns them.
  final groups = <int, List<ViHeapObject>>{};
  for (final o in objects) {
    if (!_controlKinds.contains(o.kind) || o.bounds == null || o.absBounds == null) continue;
    final v = nearestViewport(o);
    if (v != null) (groups[v] ??= <ViHeapObject>[]).add(o);
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final work = <ViHeapObject>[root];
    while (work.isNotEmpty) {
      final o = work.removeLast();
      final a = o.absBounds;
      if (a != null) {
        o.absBounds = HeapRect(top: a.top + dTop, left: a.left + dLeft, bottom: a.bottom + dTop, right: a.right + dLeft);
      }
      final cs = kids[o.oid];
      if (cs != null) work.addAll(cs);
    }
  }

  groups.forEach((vOid, controls) {
    final v = byOid[vOid];
    if (v?.absBounds == null) return;
    var minTop = controls.first.bounds!.top;
    var minLeft = controls.first.bounds!.left;
    for (final c in controls) {
      if (c.bounds!.top < minTop) minTop = c.bounds!.top;
      if (c.bounds!.left < minLeft) minLeft = c.bounds!.left;
    }
    for (final c in controls) {
      final newTop = v!.absBounds!.top + (c.bounds!.top - minTop);
      final newLeft = v.absBounds!.left + (c.bounds!.left - minLeft);
      shiftSubtree(c, newTop - c.absBounds!.top, newLeft - c.absBounds!.left);
    }
  });
}
