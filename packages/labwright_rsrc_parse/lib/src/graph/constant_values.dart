part of '../graph.dart';

const int _intCertainCeil = 0x800000;

const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

const Set<int> _zeroPayloadLengths = {5, 9};

// TODO: absolute (type 0) and UNC (type 2) path text is not decoded.
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

Object? decodeBdConstantValue({
  required HeapObjectClass carrier,
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
    case HeapObjectClass.pathControl:
      return decodeFlatPathText(raw);
    case HeapObjectClass.stringOrArrayControl:
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((byte) => byte >= 0x20 && byte < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case HeapObjectClass.booleanOrClusterControl:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case HeapObjectClass.enumRingControl when hasEnumItems:
    case HeapObjectClass.clusterShell when hasEnumItems:
    case HeapObjectClass.numericControl:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != HeapObjectClass.numericControl || raw == null) return null;
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

// TODO: payloads stored wider than their numeric type, and arrays of non-numeric elements, are not decoded.
void _typedBdConstDecode(ViHeapObject object) {
  final flat = object.constValueRaw;
  final type = object.resolvedType;
  if (flat == null || type == null) return;
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
    object.constNumeric = value;
    return;
  }
  if (type.kind == ViDataType.string) {
    if (object.constValueScalar || flat.length < 4) return;
    final declared = ByteData.sublistView(flat).getUint32(0);
    if (4 + declared == flat.length) {
      object.constText = String.fromCharCodes(flat, 4);
    } else if (declared == 0 && flat.length == 5 && flat[4] == 0) {
      object.constText = '';
    }
    return;
  }
  if (type.kind != ViDataType.array) return;
  final element = object.resolvedElementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount == null || dimCount < 1 || dimCount > 8) {
    return;
  }
  final elementSize = _flatNumericSize(element.kind);
  if (elementSize == null || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var dim = 0; dim < dimCount; dim++) view.getUint32(4 * dim)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final expected = 4 * dimCount + count * elementSize;
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (flat.length != expected && !emptyPadded) return;
  object.constArrayDims = dims;
  object.constArray = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

void decodeBdConstValues(ViDiagram diagram) {
  final nodeKids = _childrenByParentOid(diagram.objects);
  bool subtreeHasItems(ViHeapObject object, [int depth = 0]) {
    if (object.items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in nodeKids[object.oid] ?? const <ViHeapObject>[]) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final object in diagram.objects) {
    if (object.objectClass != HeapObjectClass.bdConstDco || object.constValueRaw == null) continue;
    _typedBdConstDecode(object);
    final kids = nodeKids[object.oid];
    if (kids == null || kids.isEmpty) continue;
    final carrier = kids.first.objectClass;
    final wantsItems = carrier == HeapObjectClass.enumRingControl || carrier == HeapObjectClass.clusterShell;
    final value = decodeBdConstantValue(
      carrier: carrier,
      flat: object.constValueRaw,
      scalar: object.constValueScalar,
      hasEnumItems: wantsItems && subtreeHasItems(object),
    );
    if (value is bool) object.constBool ??= value;
    if (value is num) object.constNumeric ??= value;
    if (value is String) object.constText ??= value;
  }
}
