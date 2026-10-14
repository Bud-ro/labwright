import 'dart:typed_data';

import '../heap/heap.dart';
import '../heap/heap_tree.dart';

/// A scalar or flag attribute record.
HeapRecordNode attr(HeapAttribute attribute, HeapAttrWidth width, int value) =>
    HeapRecordNode(encodeHeapScalarAttr(attribute.raw, width, value));

/// A rectangle attribute record.
HeapRecordNode rectAttr(HeapAttribute attribute, HeapRect rect) =>
    HeapRecordNode(encodeHeapRectAttr(attribute.raw, rect));

/// A container attribute record over [payload].
HeapRecordNode containerAttr(HeapAttribute attribute, List<int> payload) =>
    HeapRecordNode(encodeHeapContainerAttr(attribute.raw, payload));

/// A rectangle C4 record of [opcode].
HeapRecordNode c4Rect(HeapOpcode opcode, HeapRect rect) =>
    HeapRecordNode(encodeHeapC4Record(opcode.byte, rect.payload));

/// A caption C4 record.
HeapRecordNode caption(String text) => HeapRecordNode(encodeHeapC4Record(HeapOpcode.caption.byte, text.codeUnits));

/// A reference record of [kind] to [oid].
HeapRecordNode ref(HeapRefKind kind, int oid) => rawRef(kind.raw, oid);

/// A reference record with the ten-bit [rawId] to [oid].
HeapRecordNode rawRef(int rawId, int oid) => HeapRecordNode(encodeHeapRef(0x14 | (rawId >> 8), rawId & 0xff, oid));

/// A record verbatim.
HeapRecordNode raw(List<int> bytes) => HeapRecordNode(Uint8List.fromList(bytes));

/// An object of [kind] with id [oid] related to its parent by [rawTag].
HeapObjectNode object(int kind, int oid, {int rawTag = 0x19, List<HeapNode> children = const []}) =>
    HeapObjectNode.create(kind, oid, rawTag: rawTag, children: [...children]);

/// A counted list with the ten-bit [rawId].
HeapGroupNode list(int rawId, [List<HeapNode> children = const []]) =>
    HeapGroupNode.counted(rawId, children: [...children]);

/// A group whose open record carries [word] rather than a count.
HeapGroupNode worded(int rawId, int word, [List<HeapNode> children = const []]) =>
    HeapGroupNode.worded(rawId, word, children: [...children]);

/// The zero rectangle.
const HeapRect kZeroRect = HeapRect(top: 0, left: 0, bottom: 0, right: 0);
