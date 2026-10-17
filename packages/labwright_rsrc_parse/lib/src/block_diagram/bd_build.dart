/// Builds a [BdDiagram] from a `BDHb` body: [buildBlockDiagram] runs the shared heap walk
/// with the block diagram's own records and attributes, then the passes that depend on the
/// finished tree. [decodeBdConstValues] runs once the data-space join has resolved each
/// constant's type.
///
/// Which records feed which block-diagram fields, beyond the shared ones:
///
/// ```text
/// record                                   field
/// C4 path (0xa4), symbolName (0xc4)        BdForeignCall.libraryPath, entryPoint
/// attributes                               BdConstant.raw and text, termBounds, termBmp,
///                                          BdPrimitive.primResId, BdFrames.dIdx,
///                                          BdSignal.wireTableRaw and lastSignalKind,
///                                          BdCaseFrames.defaultFrameIndex, structRgb
/// case selector groups                     BdCaseFrames.selectorRanges, selectorStrings
/// array index group                        arrayIndex
/// ```
library;

import 'dart:typed_data';

import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/heap_walk.dart';
import 'bd_diagram.dart';
import 'bd_object.dart';

const int _structureAreaCap = 20000;

int _signedAtWidth(int value, HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.u8 => value.toSigned(8),
  HeapAttrWidth.u16 => value.toSigned(16),
  HeapAttrWidth.u24 => value.toSigned(24),
  HeapAttrWidth.rgb => value.toSigned(32),
  _ => value,
};

String? _selectorPoolString(Uint8List body, int offset, int lead, int span) {
  if (lead == kHeapRecordPrefix) {
    if (offset + 3 > body.length) return null;
    final count = body[offset + 2];
    if (3 + count > span || offset + 3 + count > body.length) return null;
    return String.fromCharCodes(body.sublist(offset + 3, offset + 3 + count));
  }
  final attr = decodeHeapAttr(body, offset);
  final value = attr?.asInt;
  if (attr == null || value == null) return null;
  final bytes = heapAttrScalarBytes(attr.width) ?? 0;
  final chars = [for (var i = bytes - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

/// A case structure's selector range list or string pool.
class _SelectorCapture extends HeapGroupCapture<BdObject> {
  _SelectorCapture(super.owner, this.frames, {required this.inPool});

  final BdCaseFrames frames;
  final bool inPool;
  final List<ViSelectorRange> _ranges = [];
  final List<String> _strings = [];
  bool _entryOpen = false;
  int _low = 0, _high = 0, _lowBound = 0, _highBound = 0, _frame = 0;

  @override
  void openGroup(int tag) {
    if (tag == HeapGroupTag.selectorRange.tag && depth == 2 && !inPool) {
      _entryOpen = true;
      _low = _high = _lowBound = _highBound = _frame = 0;
    }
  }

  @override
  void closeGroup() {
    if (_entryOpen && depth == 1) {
      _ranges.add(
        ViSelectorRange(
          low: _low,
          high: _high,
          lowBound: ViSelectorBound.ofCode(_lowBound),
          highBound: ViSelectorBound.ofCode(_highBound),
          frame: _frame,
        ),
      );
      _entryOpen = false;
    }
    if (depth != 0) return;
    if (inPool) {
      if (frames.selectorStrings.isEmpty) frames.selectorStrings = _strings;
    } else if (frames.selectorRanges.isEmpty) {
      frames.selectorRanges = _ranges;
    }
  }

  @override
  bool record(Uint8List body, ByteData view, int offset, int lead, int length) {
    if (inPool) {
      final value = _selectorPoolString(body, offset, lead, length);
      if (value == null) return false;
      _strings.add(value);
      return true;
    }
    if (!_entryOpen) return false;
    final attr = decodeHeapAttrIn(view, body, offset);
    final value = attr?.asInt;
    if (attr == null || value == null) return false;
    final tag = attr.rawTag;
    if (tag == SelectorRangeAttr.low.raw) {
      _low = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.high.raw) {
      _high = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.lowBound.raw) {
      _lowBound = value;
    } else if (tag == SelectorRangeAttr.highBound.raw) {
      _highBound = value;
    } else if (tag == SelectorRangeAttr.frame.raw) {
      _frame = value;
    } else {
      return false;
    }
    return true;
  }
}

class _BdWalk extends HeapWalkListener<BdObject> {
  @override
  BdObject createObject({required int oid, required int kind, required int offset}) =>
      BdObject(oid: oid, kind: kind, offset: offset);

  @override
  HeapGroupCapture<BdObject>? captureGroup(BdObject owner, int tag) {
    if (owner.caseFrames case final frames? when kViSelectorGroupTags.contains(tag)) {
      return _SelectorCapture(owner, frames, inPool: tag == HeapGroupTag.selectorStringPool.tag);
    }
    if (tag == HeapGroupTag.arrayIndex.tag && owner.objectClass == BdObjectClass.array) {
      return ArrayIndexCapture(owner);
    }
    return null;
  }

  @override
  Set<HeapAttribute> get attributes => const {
    HeapAttribute.compressedWireTable,
    HeapAttribute.constValue,
    HeapAttribute.cosmColorB,
    HeapAttribute.dIdx,
    HeapAttribute.lastSignalKind,
    HeapAttribute.primResID,
    HeapAttribute.selectDefaultCase,
    HeapAttribute.structColor,
    HeapAttribute.termBMPs,
    HeapAttribute.termBounds,
  };

  @override
  void onRecord(BdObject cur, int opcode, Uint8List body, int start, int end) {
    final call = cur.foreignCall;
    if (call == null) return;
    if (opcode == HeapOpcode.path.byte) {
      call.libraryPath ??= heapRecordPath(Uint8List.sublistView(body, start, end));
    } else if (opcode == HeapOpcode.symbolName.byte) {
      call.entryPoint ??= heapRecordText(Uint8List.sublistView(body, start, end));
    }
  }

  @override
  void onAttribute(BdObject cur, HeapAttrReading attr) {
    switch (attr.attribute) {
      case HeapAttribute.constValue:
        final constant = cur.constant;
        if (constant == null) return;
        if (attr.asString case final text? when text.isNotEmpty) constant.text ??= text;
        if (constant.raw == null) {
          constant.raw = attr.flatBytes;
          constant.scalar = attr.scalarBytes != null;
        }
      case HeapAttribute.cosmColorB:
        if (cur.isTextLabel) cur.labelModeWord ??= attr.asInt;
      case HeapAttribute.termBounds:
        cur.termBounds ??= attr.asRect;
      case HeapAttribute.termBMPs:
        cur.termBmp ??= attr.asInt;
      case HeapAttribute.primResID:
        if (cur.primitive case final primitive? when attr.scalarBytes == 2) primitive.primResId ??= attr.asInt;
      case HeapAttribute.dIdx:
        cur.frames?.dIdx ??= attr.asInt;
      case HeapAttribute.compressedWireTable:
        cur.signal?.wireTableRaw ??= attr.flatBytes;
      case HeapAttribute.selectDefaultCase:
        final frame = attr.asInt;
        if (cur.caseFrames case final frames? when frame != null && frame != kViNoDefaultFrame) {
          frames.defaultFrameIndex ??= frame;
        }
      case HeapAttribute.lastSignalKind:
        final word = attr.asInt;
        if (cur.signal case final signal? when word != null && word <= 0xffff) signal.lastSignalKind ??= word;
      case HeapAttribute.structColor:
        cur.structRgb ??= attr.rgb;
      default:
        break;
    }
  }
}

/// Builds the object tree of a `BDHb` body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, flat-sequence frames are shifted
/// to their declared offsets, items and help text bubble up to the owning control, unknown
/// classes that look like nodes become nodes, unlabelled nodes take their first child label,
/// and controls under a scrolled viewport are re-anchored.
BdDiagram buildBlockDiagram(Uint8List body, {String? version, int sectionIndex = 0}) {
  final diagram = BdDiagram(objects: walkHeap(body, _BdWalk()), version: version, sectionIndex: sectionIndex);
  rebaseLabelBounds(diagram);
  _shiftFlatSequenceFrames(diagram);
  bubbleItemsToControls(diagram, isControl: (o) => o.objectClass.isControlTerminal);
  bubbleHelpText(diagram);
  _promoteUnknownNodes(diagram);
  _labelNodesFromChildren(diagram);
  reanchorScrolledControls(
    diagram,
    isPane: (o) => o.objectClass == BdObjectClass.pane,
    isControl: (o) => o.objectClass.isControlTerminal,
  );
  return diagram;
}

void _shiftFlatSequenceFrames(BdDiagram diagram) {
  for (final object in diagram.objects) {
    if (object.objectClass != BdObjectClass.flatSequence || object.absBounds == null) continue;
    for (final frame in diagram.childrenOf(object)) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      final owner = object.absBounds;
      if (frame.objectClass != BdObjectClass.sequenceFrame || local == null || abs == null || owner == null) {
        continue;
      }
      shiftSubtree(diagram, frame, dTop: owner.top + local.top - abs.top, dLeft: owner.left + local.left - abs.left);
    }
  }
}

void _promoteUnknownNodes(BdDiagram diagram) {
  for (final object in diagram.objects) {
    if (object.category != BdObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (diagram.parentOf(object)?.objectClass != BdObjectClass.frame) continue;
    final cs = diagram.childrenOf(object);
    if (cs.isEmpty) continue;
    final hasStructural = cs.any((c) => c.kind == kNodeEndpointDcoKind);
    final hasConnector = cs.any((c) => c.objectClass == BdObjectClass.connectorTerminal);
    if (!hasStructural || hasConnector) continue;
    object.category = BdObjectKind.node;
  }
}

void _labelNodesFromChildren(BdDiagram diagram) {
  for (final object in diagram.objects) {
    if (object.category != BdObjectKind.node || object.label != null) continue;
    final caps = diagram
        .childrenOf(object)
        .where((c) => c.isTextLabel)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }
}

const int _intCertainCeil = 0x800000;

const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

const Set<int> _zeroPayloadLengths = {5, 9};

// TODO: absolute (type 0) and UNC (type 2) path text is not decoded.
/// The segments of a flat relative `PTH0` path joined with backslashes; null for any other
/// path form.
String? decodeFlatPathText(Uint8List? raw) {
  if (raw == null || raw.length < 12) return null;
  if (raw[0] != 0x50 || raw[1] != 0x54 || raw[2] != 0x48 || raw[3] != 0x30) {
    return null;
  }
  final view = ByteData.sublistView(raw);
  final contentLength = view.getUint32(4);
  final end = 8 + contentLength;
  if (end > raw.length) return null;
  final pathType = view.getUint16(8);
  final count = view.getUint16(10);
  if (pathType != 1 || count < 1) return null;
  var offset = 12;
  final segments = <String>[];
  for (var i = 0; i < count; i++) {
    if (offset >= end) return null;
    final len = raw[offset];
    if (offset + 1 + len > end) return null;
    segments.add(String.fromCharCodes(raw, offset + 1, offset + 1 + len));
    offset += 1 + len;
  }
  if (offset != end) return null;
  return segments.join(r'\');
}

/// A constant's value read from its flat bytes by the class of the control that draws it:
/// a path, a four-character string, a boolean, or a small non-negative integer, a zero or a
/// double in a plausible range; null when the bytes do not fit the carrier.
Object? decodeBdConstantValue({
  required BdObjectClass carrier,
  required Uint8List? flat,
  required bool scalar,
  bool hasEnumItems = false,
}) {
  if (flat == null) return null;
  final scalarBytes = scalar ? flat.length : null;
  int? scalarValue;
  if (scalar) {
    var magnitude = 0;
    for (final byte in flat) {
      magnitude = (magnitude << 8) | byte;
    }
    scalarValue = magnitude;
  }
  final raw = scalar ? null : flat;
  switch (carrier) {
    case BdObjectClass.path:
      return decodeFlatPathText(raw);
    case BdObjectClass.string:
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((b) => b >= 0x20 && b < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case BdObjectClass.boolean:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case BdObjectClass.enumRing when hasEnumItems:
    case BdObjectClass.typeDefinition when hasEnumItems:
    case BdObjectClass.numeric:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != BdObjectClass.numeric || raw == null) return null;
      if (_zeroPayloadLengths.contains(raw.length) && raw.every((byte) => byte == 0)) {
        return 0;
      }
      if (raw.length == 8) {
        final f64Reading = ByteData.sublistView(raw).getFloat64(0);
        if (!f64Reading.isFinite) return null;
        if (f64Reading == 0 || (f64Reading.abs() >= _dblWindowFloor && f64Reading.abs() <= _dblWindowCeil)) {
          return f64Reading;
        }
      }
      return null;
    default:
      return null;
  }
}

int? _flatNumericSize(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

num _flatNumericAt(Uint8List flat, int offset, ViDataType kind, int size) {
  if (kind == ViDataType.sgl) return ByteData.sublistView(flat).getFloat32(offset);
  if (kind == ViDataType.dbl) return ByteData.sublistView(flat).getFloat64(offset);
  var value = 0;
  for (var i = 0; i < size; i++) {
    value = (value << 8) | flat[offset + i];
  }
  final signed = kind == ViDataType.i8 || kind == ViDataType.i16 || kind == ViDataType.i32 || kind == ViDataType.i64;
  return signed ? value.toSigned(8 * size) : value;
}

// TODO: payloads stored wider than their numeric type, and arrays of elements other than numbers
// and strings, are not decoded.
void _typedConstDecode(BdConstant constant, ViResolvedType resolved) {
  final flat = constant.raw;
  final type = resolved.type;
  if (flat == null) return;
  final scalarSize = _flatNumericSize(type.kind);
  if (scalarSize != null) {
    if (flat.isEmpty || flat.length > scalarSize) return;
    if (flat.length < scalarSize && (type.kind == ViDataType.sgl || type.kind == ViDataType.dbl)) {
      return;
    }
    final size = flat.length;
    final kind = size < scalarSize ? ViDataType.u64 : type.kind;
    final value = _flatNumericAt(flat, 0, kind, size);
    if (value is double && !value.isFinite) return;
    constant.numeric = value;
    return;
  }
  if (type.kind == ViDataType.string) {
    if (constant.scalar || flat.length < 4) return;
    final declared = ByteData.sublistView(flat).getUint32(0);
    if (4 + declared == flat.length) {
      constant.text = String.fromCharCodes(flat, 4);
    } else if (declared == 0 && flat.length == 5 && flat[4] == 0) {
      constant.text = '';
    }
    return;
  }
  if (type is! ViArrayType) return;
  final element = resolved.elementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount < 1 || dimCount > 8) return;
  final elementSize = _flatNumericSize(element.kind);
  if ((elementSize == null && element.kind != ViDataType.string) || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var d = 0; d < dimCount; d++) view.getUint32(4 * d)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (elementSize == null) {
    final texts = <String>[];
    var at = 4 * dimCount;
    for (var i = 0; i < count; i++) {
      if (at + 4 > flat.length) return;
      final length = view.getUint32(at);
      if (at + 4 + length > flat.length) return;
      texts.add(String.fromCharCodes(flat, at + 4, at + 4 + length));
      at += 4 + length;
    }
    if (at != flat.length && !emptyPadded) return;
    constant.arrayDims = dims;
    constant.textArray = texts;
    return;
  }
  final expected = 4 * dimCount + count * elementSize;
  if (flat.length != expected && !emptyPadded) return;
  constant.arrayDims = dims;
  constant.array = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

/// Fills every constant's [BdConstant] fields: through its resolved type first, then through
/// [decodeBdConstantValue] for the fields still unset.
void decodeBdConstValues(BdDiagram diagram) {
  bool subtreeHasItems(BdObject o, [int depth = 0]) {
    if (o.items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in diagram.childrenOf(o)) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final object in diagram.objects) {
    final constant = object.constant;
    if (constant == null || constant.raw == null) continue;
    if (object.resolvedType case final resolved?) _typedConstDecode(constant, resolved);
    final kids = diagram.childrenOf(object);
    if (kids.isEmpty) continue;
    final carrier = kids.first.objectClass;
    final wantsItems = carrier == BdObjectClass.enumRing || carrier == BdObjectClass.typeDefinition;
    final value = decodeBdConstantValue(
      carrier: carrier,
      flat: constant.raw,
      scalar: constant.scalar,
      hasEnumItems: wantsItems && subtreeHasItems(object),
    );
    if (value is bool) constant.boolValue ??= value;
    if (value is num) constant.numeric ??= value;
    if (value is String) constant.text ??= value;
  }
}
