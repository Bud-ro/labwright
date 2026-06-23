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

  /// Heuristic role — wire (class `0x68`), bounded (has a rectangle), or other.
  ViObjectRole get role => kind == 0x68
      ? ViObjectRole.wire
      : (bounds != null ? ViObjectRole.bounded : ViObjectRole.other);
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
      continue;
    }
    if (cur == null) continue;
    if (lead == kHeapRecordPrefix) {
      final rec = c4FrameAt(body, o, sectionTag);
      if (rec == null) continue;
      if (rec.kind == HeapOpcode.bounds) {
        cur.bounds ??= rec.bounds;
      } else if (rec.kind == HeapOpcode.caption) {
        cur.label ??= rec.text;
      }
    } else if (lead == 0x14 && o + 6 <= n && body[o + 1] == 0x19 && body[o + 2] == 0x01 && body[o + 3] == 0xfd) {
      cur.refs.add((body[o + 4] << 8) | body[o + 5]);
    }
  }
  return ViDiagram(sectionTag: sectionTag, objects: objects);
}
