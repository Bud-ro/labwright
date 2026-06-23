import 'dart:typed_data';

import 'heap.dart';

/// The role of a block-diagram object, inferred from its class code and contents.
///
/// **Heuristic**: the full `mid` class-code catalog is not yet decoded, so this is
/// a coarse, honest classification (corpus-validated split), not the exact
/// LabVIEW node taxonomy.
enum ViObjectRole {
  /// A connection/signal object (class `0x68`) that links other objects — i.e. a
  /// wire. Carries reference ids, has no bounds.
  wire,

  /// A bounded object (node, terminal, structure, or decoration) — has a rectangle.
  bounded,

  /// Neither a wire nor a bounded object (e.g. an empty connection stub).
  other,
}

/// The structural category of a heap object, from its class code + signals
/// (corpus-validated classifier — see [classifyObject]). Coarser kinds are
/// confirmed >90%; node-vs-subVI and control-vs-indicator are *not* separable
/// from `BDEx` alone, so they are not distinguished here.
enum ViObjectKind {
  /// A wire / signal connection (class `0x68`).
  wire,

  /// A node's terminal/connector cluster (class `0x0c`; carries `C4 1F` terminals).
  terminalCluster,

  /// A control/indicator/junction terminal (a small, often wire-referenced object).
  terminal,

  /// A function / subVI node body (class `0x12`).
  node,

  /// A structure (loop/case/sequence) or the diagram frame (classes `0x53/52/09`).
  structure,

  /// A decoration (unlabeled, never-wired large rect).
  decoration,

  /// Not classifiable from the available signals.
  unknown,
}

/// The inferred data-type kind of an object, from its attached `C4` records
/// (corpus-validated payload rules — see [inferTypeKind]). Bool/string/array/
/// cluster are *not* payload-encoded and so are not inferred here.
enum ViTypeKind {
  /// Integer numeric (a `C4 74` format string with a `b`/`d`/`o`/`x`/`X` conv).
  numericInt,

  /// Floating-point numeric (a `C4 74` format with an `e`/`f`/`g`/`p` conv).
  numericFloat,

  /// Enum / ring control (a `C4 2E` item list).
  enumRing,

  /// A filesystem/library path (`C4 A4` `PTH0`).
  path,

  /// A Call-Library node (`C4 C4` symbol, paired with a `C4 A4` library path) —
  /// not a data type per se, but a useful classification.
  clnNode,

  /// No data-type signal present.
  unknown,
}

/// One object in a block-diagram heap, recovered by [buildDiagram].
///
/// Objects begin at the header record `10 19 02 fe <u16 kind> fd <u16 oid>`
/// (corpus-validated: `oid` is unique within a VI — 0/398 violations). The
/// records that follow attach to the object: `C4 2D` → [bounds], `C4 22` →
/// [label], `14 19 01 fd <id>` → a reference in [refs] (97.7% of which resolve to
/// another object's `oid`; 99.7% for wire endpoints).
class ViHeapObject {
  ViHeapObject({required this.oid, required this.kind, required this.offset});

  /// The object's unique id (the `oid` field of its header).
  final int oid;

  /// The object's class code (the `kind`/`mid` field of its header). The full
  /// class catalog is not yet decoded; `0x68` is the wire/connection class.
  final int kind;

  /// Byte offset of the object's header within the heap body.
  final int offset;

  /// The object's bounding rectangle (from a `C4 2D` record), or null (wires have
  /// none).
  HeapRect? bounds;

  /// The object's label/caption (from a `C4 22` record), or null.
  String? label;

  /// Object-id references this object holds (from `14 19 01 fd <id>` records).
  /// For [ViObjectRole.wire] objects these are the wire's endpoints.
  final List<int> refs = <int>[];

  /// Number of `C4 1F` terminal records attached (a node terminal-cluster's
  /// terminal count). Set during [buildDiagram].
  int termCount = 0;

  /// Structural category (set during [buildDiagram] once wire-reference counts
  /// are known). See [ViObjectKind].
  ViObjectKind category = ViObjectKind.unknown;

  /// Inferred data-type kind from attached `C4` records. See [ViTypeKind].
  ViTypeKind typeKind = ViTypeKind.unknown;

  /// Heuristic role — wire (class `0x68`), bounded (has a rectangle), or other.
  ViObjectRole get role => kind == 0x68
      ? ViObjectRole.wire
      : (bounds != null ? ViObjectRole.bounded : ViObjectRole.other);
}

/// Classifies a heap object into a [ViObjectKind] from its class code and signals
/// (corpus-validated; see `docs/vi-rsrc-and-heap-format.md`). `wireRefCount` is
/// how many wires reference this object's oid.
ViObjectKind classifyObject({
  required int kind,
  required bool hasBounds,
  required int termCount,
  required int wireRefCount,
}) {
  if (kind == 0x68) return ViObjectKind.wire;
  if (kind == 0x0c || termCount >= 1) return ViObjectKind.terminalCluster;
  if (kind == 0x12) return ViObjectKind.node;
  if (kind == 0x53 || kind == 0x52 || kind == 0x09) return ViObjectKind.structure;
  const wireTerminals = {0x50, 0x51, 0x57, 0x4f, 0x5b, 0xdf};
  if (wireRefCount > 0 && wireTerminals.contains(kind)) return ViObjectKind.terminal;
  const fpTerminals = {0x0a, 0x0b, 0x0d, 0xe0};
  if (fpTerminals.contains(kind)) return ViObjectKind.terminal;
  const decorations = {0x8f, 0xe7, 0xd2, 0xc7, 0xc8};
  if (wireRefCount == 0 && decorations.contains(kind)) return ViObjectKind.decoration;
  return ViObjectKind.unknown;
}

/// The printf conversion char of a `C4 74` numeric format-string payload (e.g.
/// `g` from `%#_6g`), or null.
int? _formatConvChar(List<int> payload) {
  var seenPercent = false;
  for (final c in payload) {
    if (!seenPercent) {
      if (c == 0x25) seenPercent = true; // '%'
      continue;
    }
    final isAlpha = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    if (isAlpha) return c;
  }
  return null;
}

/// Infers a [ViTypeKind] from the set of `C4` opcodes attached to an object plus
/// the numeric format payload (if any). Payload-grounded (corpus-validated >90%).
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

/// A recovered block-diagram (or other heap) as a graph of [ViHeapObject]s plus
/// the wire connections between them. **Partial/honest**: object *kinds* are raw
/// class codes (catalog undecoded) and wire direction is not determined.
class ViDiagram {
  ViDiagram({required this.sectionTag, required this.objects});

  /// The section this diagram came from (`BDEx` = block diagram).
  final String sectionTag;

  /// All recovered objects, in heap order.
  final List<ViHeapObject> objects;

  /// Objects indexed by their unique [ViHeapObject.oid].
  Map<int, ViHeapObject> get byId => {for (final o in objects) o.oid: o};

  /// The wire/connection objects (class `0x68` with ≥2 distinct endpoints).
  Iterable<ViHeapObject> get wires =>
      objects.where((o) => o.kind == 0x68 && o.refs.toSet().length >= 2);

  /// The bounded objects (nodes / terminals / structures / decorations).
  Iterable<ViHeapObject> get nodes => objects.where((o) => o.bounds != null);

  /// Wire connections resolved to objects: each entry is a wire and the endpoint
  /// objects (by `oid`) it links that exist in this diagram.
  List<ViConnection> get connections {
    final ids = byId;
    final out = <ViConnection>[];
    for (final w in wires) {
      final ends = <ViHeapObject>[];
      for (final r in w.refs.toSet()) {
        final t = ids[r];
        if (t != null) ends.add(t);
      }
      if (ends.length >= 2) out.add(ViConnection(wire: w, endpoints: ends));
    }
    return out;
  }
}

/// A wire and the objects it connects (endpoint direction is not yet decoded).
class ViConnection {
  ViConnection({required this.wire, required this.endpoints});

  /// The wire/connection object.
  final ViHeapObject wire;

  /// The endpoint objects the wire links.
  final List<ViHeapObject> endpoints;
}

/// Recovers the [ViDiagram] from a decompressed heap [body] (e.g. a `BDEx`
/// section's bytes) by walking its record stream ([walkHeapBody]), segmenting it
/// into objects at each `10 19 02 fe <kind> fd <oid>` header, and attaching the
/// bounds / label / reference records that follow. Total/bounds-safe.
ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDEx'}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final fmt = <ViHeapObject, List<int>>{};
  ViHeapObject? cur;
  final n = body.length;
  for (final s in walkHeapBody(body).spans) {
    final o = s.offset;
    final lead = s.lead;
    // Object header: 10 19 02 fe <u16 kind> fd <u16 oid>
    if (lead == 0x10 &&
        o + 9 <= n &&
        body[o + 1] == 0x19 &&
        body[o + 2] == 0x02 &&
        body[o + 3] == 0xfe &&
        body[o + 6] == 0xfd) {
      cur = ViHeapObject(
        oid: (body[o + 7] << 8) | body[o + 8],
        kind: (body[o + 4] << 8) | body[o + 5],
        offset: o,
      );
      objects.add(cur);
      c4ops[cur] = <int>{};
      continue;
    }
    if (cur == null) continue;
    if (lead == kHeapRecordPrefix) {
      final rec = c4FrameAt(body, o, sectionTag);
      if (rec == null) continue;
      c4ops[cur]!.add(rec.opcode);
      if (rec.opcode == 0x2d) {
        cur.bounds ??= rec.bounds;
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

  // Post-pass: wire-reference counts, then classify + infer type.
  final ids = {for (final o in objects) o.oid: o};
  final wireRefs = <int, int>{};
  for (final o in objects) {
    if (o.kind != 0x68) continue;
    for (final r in o.refs.toSet()) {
      if (ids.containsKey(r)) wireRefs[r] = (wireRefs[r] ?? 0) + 1;
    }
  }
  for (final o in objects) {
    o.category = classifyObject(
      kind: o.kind,
      hasBounds: o.bounds != null,
      termCount: o.termCount,
      wireRefCount: wireRefs[o.oid] ?? 0,
    );
    o.typeKind = inferTypeKind(c4ops[o] ?? const <int>{}, fmt[o]);
  }
  return ViDiagram(sectionTag: sectionTag, objects: objects);
}
