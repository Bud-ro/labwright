import 'dart:typed_data';

import 'heap.dart';

/// The records of an object or group that read as one thing: a scalar attribute by its
/// [HeapAttribute], a C4 record by its opcode, a group by its tag, the objects inside.
extension HeapNodeRecords on List<HeapNode> {
  /// The scalar or flag attribute [attribute], or null.
  HeapAttr? attr(HeapAttribute attribute) {
    for (final node in this) {
      if (node is HeapRecordNode) {
        final decoded = decodeHeapAttr(node.bytes, 0);
        if (decoded != null && decoded.attribute == attribute && decoded.length == node.bytes.length) return decoded;
      }
    }
    return null;
  }

  /// The first C4 record of [opcode], or null.
  HeapRecord? c4(HeapOpcode opcode) {
    for (final node in this) {
      if (node is HeapRecordNode && node.bytes[0] == kHeapRecordPrefix && node.bytes[1] == opcode.byte) {
        return c4FrameAt(node.bytes, 0, '');
      }
    }
    return null;
  }

  /// The bounds record as a rectangle, or null.
  HeapRect? get bounds => c4(HeapOpcode.bounds)?.rect;

  /// The group opened with [tag], or null.
  HeapGroupNode? group(int tag) {
    for (final node in this) {
      if (node is HeapGroupNode && node.tag == tag) return node;
    }
    return null;
  }

  /// The objects directly inside, in order.
  Iterable<HeapObjectNode> get objects => whereType<HeapObjectNode>();

  /// The reference records inside, in order.
  Iterable<HeapRef> get refs sync* {
    for (final node in this) {
      if (node is HeapRecordNode) {
        final ref = decodeHeapRef(node.bytes, 0);
        if (ref != null && ref.length == node.bytes.length) yield ref;
      }
    }
  }

  /// Replaces the first record [HeapAttribute] [attribute] names with one of the same width
  /// holding [value]; false when there is none.
  bool setAttr(HeapAttribute attribute, int value) {
    for (var i = 0; i < length; i++) {
      final node = this[i];
      if (node is! HeapRecordNode) continue;
      final decoded = decodeHeapAttr(node.bytes, 0);
      if (decoded == null || decoded.attribute != attribute || decoded.length != node.bytes.length) continue;
      this[i] = HeapRecordNode(encodeHeapScalarAttr(decoded.rawTag, decoded.width, value));
      return true;
    }
    return false;
  }

  /// Replaces the bounds record with [rect]; false when there is none.
  bool setBounds(HeapRect rect) {
    for (var i = 0; i < length; i++) {
      final node = this[i];
      if (node is HeapRecordNode && node.bytes[0] == kHeapRecordPrefix && node.bytes[1] == HeapOpcode.bounds.byte) {
        this[i] = HeapRecordNode(encodeHeapC4Record(HeapOpcode.bounds.byte, rect.payload));
        return true;
      }
    }
    return false;
  }
}

/// A rectangle attribute record: the ten-bit [rawId] over [rect]'s four `i16`s.
Uint8List encodeHeapRectAttr(int rawId, HeapRect rect) =>
    Uint8List.fromList([0xc4 | (rawId >> 8), rawId & 0xff, 0x08, ...rect.payload]);

/// A container attribute record: the ten-bit [rawId] over [payload], its length in one byte
/// or, from `0xff` bytes on, behind an `0xff` escape as a word.
Uint8List encodeHeapContainerAttr(int rawId, List<int> payload) => Uint8List.fromList([
  0xc4 | (rawId >> 8),
  rawId & 0xff,
  if (payload.length < 0xff) payload.length else ...[0xff, payload.length >> 8 & 0xff, payload.length & 0xff],
  ...payload,
]);

/// A scalar or flag attribute record: the ten-bit [rawId] and [value] in [width].
Uint8List encodeHeapScalarAttr(int rawId, HeapAttrWidth width, int value) {
  final bank = rawId >> 8;
  final id = rawId & 0xff;
  return Uint8List.fromList(switch (width) {
    HeapAttrWidth.flag => [(value == 0 ? 0x00 : 0x10) | 4 | bank, id],
    HeapAttrWidth.u8 => [0x20 | 4 | bank, id, value & 0xff],
    HeapAttrWidth.u16 => [0x40 | 4 | bank, id, value >> 8 & 0xff, value & 0xff],
    HeapAttrWidth.u24 => [0x60 | 4 | bank, id, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff],
    HeapAttrWidth.rgb => [0x80 | 4 | bank, id, value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff],
    _ => throw ArgumentError.value(width, 'width', 'is not a scalar'),
  });
}

/// A heap body as the tree its records form: objects from their header to their close, groups
/// from their open to their close, and every other record verbatim. [encodeHeapTree] gives
/// back the body byte for byte.
sealed class HeapNode {
  const HeapNode();

  void encodeInto(BytesBuilder out);
}

/// An object: its header, the records inside it, and whether the walk met its close.
final class HeapObjectNode extends HeapNode {
  /// A new object of [kind] with id [oid], opened and closed with the ten-bit [rawTag]: the
  /// record that relates it to its parent, `0x19` for a list item.
  HeapObjectNode.create(this.kind, this.oid, {int rawTag = 0x19, List<HeapNode>? children})
    : lead = 0x10 | (rawTag >> 8),
      tag = rawTag & 0xff,
      wide = oid >= 0x8000,
      children = children ?? [],
      closeLead = 0x08 | (rawTag >> 8),
      closeTag = rawTag & 0xff;

  HeapObjectNode({
    required this.lead,
    required this.tag,
    required this.kind,
    required this.oid,
    this.wide = false,
    this.children = const [],
    this.closeLead,
    this.closeTag,
  });

  final int lead;

  final int tag;

  final int kind;

  final int oid;

  /// Whether the header carries the id in its thirteen-byte form.
  final bool wide;

  final List<HeapNode> children;

  final int? closeLead;

  final int? closeTag;

  bool get closed => closeLead != null;

  @override
  void encodeInto(BytesBuilder out) {
    out.add(encodeHeapObjectHeader(lead, tag, kind, oid, wide: wide));
    for (final child in children) {
      child.encodeInto(out);
    }
    if (closeLead case final close?) out.add([close, closeTag!]);
  }
}

/// A group: its open record, the records inside it, and whether the walk met its close.
final class HeapGroupNode extends HeapNode {
  HeapGroupNode({required this.open, this.children = const [], this.closeLead, this.closeTag});

  /// A new counted list with the ten-bit [rawId]: its open record carries the item count,
  /// which [syncCount] keeps in step with [children].
  HeapGroupNode.counted(int rawId, {List<HeapNode>? children})
    : open = Uint8List.fromList([0x10 | (rawId >> 8), rawId & 0xff, 0x01, 0xfb, 0, 0]),
      children = children ?? [],
      closeLead = 0x08 | (rawId >> 8),
      closeTag = rawId & 0xff {
    syncCount();
  }

  /// A new group with the ten-bit [rawId] whose open record carries [word] as a `fe`-typed
  /// value rather than a count.
  HeapGroupNode.worded(int rawId, int word, {List<HeapNode>? children})
    : open = Uint8List.fromList([0x10 | (rawId >> 8), rawId & 0xff, 0x01, 0xfe, word >> 8 & 0xff, word & 0xff]),
      children = children ?? [],
      closeLead = 0x08 | (rawId >> 8),
      closeTag = rawId & 0xff;

  /// The open record, `[lead, tag, …]`, verbatim.
  final Uint8List open;

  int get tag => open[1];

  /// The ten-bit group id, from the lead's low bits and the tag.
  int get rawId => heapRawId(open[0], open[1]);

  /// Whether the open record's word counts the items, which the `fb` type tag says.
  bool get counted => open.length >= 6 && open[3] == 0xfb;

  /// Writes [children]'s length into the open record of a counted list.
  void syncCount() {
    if (counted) ByteData.sublistView(open).setUint16(4, children.length);
  }

  final List<HeapNode> children;

  final int? closeLead;

  final int? closeTag;

  @override
  void encodeInto(BytesBuilder out) {
    out.add(open);
    for (final child in children) {
      child.encodeInto(out);
    }
    if (closeLead case final close?) out.add([close, closeTag!]);
  }
}

/// Any other record, verbatim: an attribute, a reference, a C4 record, or a close the walk
/// found no scope for.
final class HeapRecordNode extends HeapNode {
  const HeapRecordNode(this.bytes);

  final Uint8List bytes;

  int get lead => bytes[0];

  @override
  void encodeInto(BytesBuilder out) => out.add(bytes);
}

/// The records of [body] after its length word, as a tree; the walk stops where
/// [recordSkip] cannot size a record, and the rest of the body is one verbatim record.
List<HeapNode> parseHeapTree(Uint8List body) {
  final roots = <HeapNode>[];
  final scopes = <List<HeapNode>>[roots];
  final openers = <HeapNode>[];
  var at = 4;
  while (at < body.length) {
    final step = recordSkip(body, at);
    if (step == null || at + step > body.length) {
      scopes.last.add(HeapRecordNode(Uint8List.sublistView(body, at)));
      break;
    }
    final lead = body[at];
    final header = isHeapObjectHeaderLead(lead) ? heapObjectHeaderLength(body, at) : 0;
    if (header != 0) {
      final node = HeapObjectNode(
        lead: lead,
        tag: body[at + 1],
        kind: heapObjectHeaderKind(body, at),
        oid: heapObjectHeaderOid(body, at, header),
        wide: header == 13,
        children: [],
      );
      scopes.last.add(node);
      scopes.add(node.children);
      openers.add(node);
    } else if (isHeapGroupOpenLead(lead) && at + 4 <= body.length && isHeapTypeTag(body[at + 3])) {
      final node = HeapGroupNode(open: Uint8List.sublistView(body, at, at + step), children: []);
      scopes.last.add(node);
      scopes.add(node.children);
      openers.add(node);
    } else if (isHeapGroupCloseLead(lead) && openers.isNotEmpty) {
      final opener = openers.removeLast();
      scopes.removeLast();
      final closed = switch (opener) {
        HeapObjectNode() => HeapObjectNode(
          lead: opener.lead,
          tag: opener.tag,
          kind: opener.kind,
          oid: opener.oid,
          wide: opener.wide,
          children: opener.children,
          closeLead: lead,
          closeTag: body[at + 1],
        ),
        HeapGroupNode() => HeapGroupNode(
          open: opener.open,
          children: opener.children,
          closeLead: lead,
          closeTag: body[at + 1],
        ),
        HeapRecordNode() => opener,
      };
      scopes.last[scopes.last.length - 1] = closed;
    } else {
      scopes.last.add(HeapRecordNode(Uint8List.sublistView(body, at, at + step)));
    }
    at += step;
  }
  return roots;
}

/// The body [nodes] encode: their records behind the length word.
Uint8List encodeHeapTree(List<HeapNode> nodes) {
  final out = BytesBuilder(copy: false)..add(const [0, 0, 0, 0]);
  for (final node in nodes) {
    node.encodeInto(out);
  }
  final bytes = out.takeBytes();
  ByteData.sublistView(bytes).setUint32(0, bytes.length - 4);
  return bytes;
}
