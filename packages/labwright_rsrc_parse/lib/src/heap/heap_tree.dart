import 'dart:typed_data';

import 'heap.dart';

/// A heap body as the tree its records form: objects from their header to their close, groups
/// from their open to their close, and every other record verbatim. [encodeHeapTree] gives
/// back the body byte for byte.
sealed class HeapNode {
  const HeapNode();

  void encodeInto(BytesBuilder out);
}

/// An object: its header, the records inside it, and whether the walk met its close.
final class HeapObjectNode extends HeapNode {
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

  /// The open record, `[lead, tag, …]`, verbatim.
  final Uint8List open;

  int get tag => open[1];

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
