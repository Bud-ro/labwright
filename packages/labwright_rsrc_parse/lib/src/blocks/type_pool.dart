import 'dart:typed_data';

import '../decode.dart';

enum ViDataType {
  voidType,
  i8,
  i16,
  i32,
  i64,
  u8,
  u16,
  u32,
  u64,
  sgl,
  dbl,
  ext,
  complexSgl,
  complexDbl,
  complexExt,
  enumU8,
  enumU16,
  enumU32,
  boolean,
  string,

  cString,

  pascalString,

  subString,
  path,
  picture,

  tag,
  array,

  arrayDataPointer,

  subArray,
  cluster,

  variant,

  measureData,

  complexFixedPoint,
  fixedPoint,
  refnum,

  block,
  typeBlock,
  voidBlock,
  alignedBlock,
  repeatedBlock,
  alignmentMarker,

  ptr,

  ptrTo,

  function,

  typeDef,

  polyVi,

  unknown,
}

abstract final class TypeCode {
  static const int voidType = 0x00;
  static const int i8 = 0x01;
  static const int i16 = 0x02;
  static const int i32 = 0x03;
  static const int i64 = 0x04;
  static const int u8 = 0x05;
  static const int u16 = 0x06;
  static const int u32 = 0x07;
  static const int u64 = 0x08;
  static const int sgl = 0x09;
  static const int dbl = 0x0a;
  static const int ext = 0x0b;
  static const int complexSgl = 0x0c;
  static const int complexDbl = 0x0d;
  static const int complexExt = 0x0e;
  static const int enumU8 = 0x15;
  static const int enumU16 = 0x16;
  static const int enumU32 = 0x17;
  static const int unitSgl = 0x19;
  static const int unitDbl = 0x1a;
  static const int unitExt = 0x1b;
  static const int unitComplexSgl = 0x1c;
  static const int unitComplexDbl = 0x1d;
  static const int unitComplexExt = 0x1e;
  static const int booleanU16 = 0x20;
  static const int boolean = 0x21;
  static const int string = 0x30;
  static const int path = 0x32;
  static const int picture = 0x33;
  static const int cString = 0x34;
  static const int pascalString = 0x35;
  static const int tag = 0x37;
  static const int subString = 0x3f;
  static const int array = 0x40;
  static const int arrayDataPointer = 0x41;
  static const int subArray = 0x4f;
  static const int cluster = 0x50;
  static const int variant = 0x53;
  static const int measureData = 0x54;
  static const int complexFixedPoint = 0x5e;
  static const int fixedPoint = 0x5f;
  static const int block = 0x60;
  static const int typeBlock = 0x61;
  static const int voidBlock = 0x62;
  static const int alignedBlock = 0x63;
  static const int repeatedBlock = 0x64;
  static const int alignmentMarker = 0x65;
  static const int refnum = 0x70;
  static const int ptr = 0x80;
  static const int ptrTo = 0x83;
  static const int function = 0xf0;
  static const int typeDef = 0xf1;
  static const int polyVi = 0xf2;
}

const Map<int, ViDataType> _typeCodes = {
  TypeCode.voidType: ViDataType.voidType,
  TypeCode.i8: ViDataType.i8,
  TypeCode.i16: ViDataType.i16,
  TypeCode.i32: ViDataType.i32,
  TypeCode.i64: ViDataType.i64,
  TypeCode.u8: ViDataType.u8,
  TypeCode.u16: ViDataType.u16,
  TypeCode.u32: ViDataType.u32,
  TypeCode.u64: ViDataType.u64,
  TypeCode.sgl: ViDataType.sgl,
  TypeCode.dbl: ViDataType.dbl,
  TypeCode.ext: ViDataType.ext,
  TypeCode.complexSgl: ViDataType.complexSgl,
  TypeCode.complexDbl: ViDataType.complexDbl,
  TypeCode.complexExt: ViDataType.complexExt,
  TypeCode.enumU8: ViDataType.enumU8,
  TypeCode.enumU16: ViDataType.enumU16,
  TypeCode.enumU32: ViDataType.enumU32,
  TypeCode.boolean: ViDataType.boolean,
  TypeCode.string: ViDataType.string,
  TypeCode.path: ViDataType.path,
  TypeCode.picture: ViDataType.picture,
  TypeCode.cString: ViDataType.cString,
  TypeCode.pascalString: ViDataType.pascalString,
  TypeCode.tag: ViDataType.tag,
  TypeCode.subString: ViDataType.subString,
  TypeCode.array: ViDataType.array,
  TypeCode.arrayDataPointer: ViDataType.arrayDataPointer,
  TypeCode.subArray: ViDataType.subArray,
  TypeCode.cluster: ViDataType.cluster,
  TypeCode.variant: ViDataType.variant,
  TypeCode.measureData: ViDataType.measureData,
  TypeCode.complexFixedPoint: ViDataType.complexFixedPoint,
  TypeCode.fixedPoint: ViDataType.fixedPoint,
  TypeCode.block: ViDataType.block,
  TypeCode.typeBlock: ViDataType.typeBlock,
  TypeCode.voidBlock: ViDataType.voidBlock,
  TypeCode.alignedBlock: ViDataType.alignedBlock,
  TypeCode.repeatedBlock: ViDataType.repeatedBlock,
  TypeCode.alignmentMarker: ViDataType.alignmentMarker,
  TypeCode.refnum: ViDataType.refnum,
  TypeCode.ptr: ViDataType.ptr,
  TypeCode.ptrTo: ViDataType.ptrTo,
  TypeCode.function: ViDataType.function,
  TypeCode.typeDef: ViDataType.typeDef,
  TypeCode.polyVi: ViDataType.polyVi,
};

ViDataType? dataTypeOfCode(int code) => _typeCodes[code];

class ViType {
  const ViType({
    required this.index,
    required this.code,
    required this.kind,
    this.name,
    this.members = const [],
    this.elementIndex,
    this.dimCount,
    this.enumItems = const [],
    this.typedefBase,
  });
  final int index;
  final int code;
  final ViDataType kind;

  final List<int> members;

  final String? name;

  final int? elementIndex;

  final int? dimCount;

  final List<String> enumItems;

  final ViType? typedefBase;
}

List<ViType> decodeTypePool(Uint8List body) {
  if (body.length < 8) return const [];
  final count = (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
  if (count <= 0 || count > 200000) return const [];
  final out = <ViType>[];
  var off = 4;
  for (var i = 0; i < count; i++) {
    if (off + 4 > body.length) break;
    final descLen = (body[off] << 8) | body[off + 1];
    if (descLen < 4 || off + descLen > body.length) break;
    out.add(_decodeDescriptor(body, off, descLen, count, i));
    off += descLen;
  }
  return out;
}

ViType _decodeDescriptor(Uint8List body, int off, int descLen, int poolCount, int index, [int depth = 0]) {
  final code = body[off + 3];
  final kind = _typeCodes[code] ?? ViDataType.unknown;
  final members = kind == ViDataType.cluster ? _clusterMembers(body, off, descLen, poolCount) : const <int>[];
  final elementIndex = kind == ViDataType.array ? _arrayElement(body, off, descLen, poolCount) : null;
  final dimCount = elementIndex == null || off + 6 > body.length ? null : (body[off + 4] << 8) | body[off + 5];
  final isEnum = kind == ViDataType.enumU8 || kind == ViDataType.enumU16 || kind == ViDataType.enumU32;
  final enumItems = isEnum ? _enumItems(body, off, descLen) : const <String>[];
  final nameStart = _nameRegionStart(body, off, kind, members, elementIndex, enumItems);
  return ViType(
    index: index,
    code: code,
    kind: kind,
    name: _trailingName(body, nameStart, off + descLen),
    members: members,
    elementIndex: elementIndex,
    dimCount: dimCount,
    enumItems: enumItems,
    typedefBase: kind == ViDataType.typeDef && depth < 8 ? _typedefBase(body, off, descLen, poolCount, depth) : null,
  );
}

const int kInlineTypeIndex = -1;

int? _typedefBaseStart(Uint8List bytes, int off, int descLen) {
  final end = off + descLen;
  if (off + 12 > end) return null;
  final componentCount = (bytes[off + 8] << 24) | (bytes[off + 9] << 16) | (bytes[off + 10] << 8) | bytes[off + 11];
  if (componentCount < 0 || componentCount > 32) return null;
  var pos = off + 12;
  for (var i = 0; i < componentCount; i++) {
    if (pos >= end) return null;
    pos += 1 + bytes[pos];
    if (pos > end) return null;
  }
  return pos + 4 <= end ? pos : null;
}

/// TODO: the inline base's length word exceeds its extent by 4; not decoded.
ViType? _typedefBase(Uint8List bytes, int off, int descLen, int poolCount, int depth) {
  final start = _typedefBaseStart(bytes, off, descLen);
  if (start == null) return null;
  final remaining = off + descLen - start;
  final declared = (bytes[start] << 8) | bytes[start + 1];
  if (declared - 4 != remaining) return null;
  return _decodeDescriptor(bytes, start, remaining, poolCount, kInlineTypeIndex, depth + 1);
}

List<int> decodeTypeTable(Uint8List body) {
  if (body.length < 8) return const [];
  final count = (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
  if (count <= 0 || count > 200000) return const [];
  var off = 4;
  for (var i = 0; i < count; i++) {
    if (off + 2 > body.length) return const [];
    final descLen = (body[off] << 8) | body[off + 1];
    if (descLen < 4 || off + descLen > body.length) return const [];
    off += descLen;
  }
  if (off + 2 > body.length) return const [];
  final n = (body[off] << 8) | body[off + 1];
  if (n <= 0 || off + 2 + n * 2 > body.length) return const [];
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final idx = (body[off + 2 + i * 2] << 8) | body[off + 3 + i * 2];
    if (idx >= count) return const [];
    out.add(idx);
  }
  return out;
}

List<int> _clusterMembers(Uint8List bytes, int off, int descLen, int poolCount) {
  if (off + 6 > bytes.length) return const [];
  final memberCount = (bytes[off + 4] << 8) | bytes[off + 5];
  if (memberCount <= 0 || memberCount > 512) return const [];
  if (6 + memberCount * 2 > descLen) return const [];
  final out = <int>[];
  for (var memberIndex = 0; memberIndex < memberCount; memberIndex++) {
    final pos = off + 6 + memberIndex * 2;
    final idx = (bytes[pos] << 8) | bytes[pos + 1];
    if (idx >= poolCount) return const [];
    out.add(idx);
  }
  return out;
}

int? _arrayElement(Uint8List bytes, int off, int descLen, int poolCount) {
  if (off + 6 > bytes.length) return null;
  final numDims = (bytes[off + 4] << 8) | bytes[off + 5];
  if (numDims < 1 || numDims > 8) return null;
  final elementIndexPos = off + 6 + numDims * 4;
  if (elementIndexPos + 2 > off + descLen) return null;
  final idx = (bytes[elementIndexPos] << 8) | bytes[elementIndexPos + 1];
  if (idx >= poolCount) return null;
  return idx;
}

int? serializedDefaultSize(ViType t, List<ViType> pool, [int depth = 0]) {
  if (depth > 64) return null;
  switch (t.code) {
    case 0x00:
      return 0;
    case 0x01:
    case 0x05:
    case 0x15:
    case 0x21:
      return 1;
    case 0x02:
    case 0x06:
    case 0x16:
      return 2;
    case 0x03:
    case 0x07:
    case 0x09:
    case 0x17:
      return 4;
    case 0x04:
    case 0x08:
    case 0x0a:
    case 0x0c:
      return 8;
    case 0x0b:
    case 0x0d:
      return 16;
    case 0x0e:
      return 32;
    case 0x70:
      return 4;
    case 0x50:
      if (t.members.isEmpty) return null;
      var total = 0;
      for (final m in t.members) {
        if (m < 0 || m >= pool.length) return null;
        final s = serializedDefaultSize(pool[m], pool, depth + 1);
        if (s == null) return null;
        total += s;
      }
      return total;
    case TypeCode.typeDef:
      final base = t.typedefBase;
      return base == null ? null : serializedDefaultSize(base, pool, depth + 1);
    default:
      return null;
  }
}

const int kDataSpaceInitTableBytes = 51 * 4;

List<String> _enumItems(Uint8List bytes, int off, int descLen) {
  if (off + 6 > bytes.length) return const [];
  final numItems = (bytes[off + 4] << 8) | bytes[off + 5];
  if (numItems < 1 || numItems > 256) return const [];
  final out = <String>[];
  var pos = off + 6;
  final endPos = off + descLen;
  for (var itemIndex = 0; itemIndex < numItems; itemIndex++) {
    if (pos >= endPos) return const [];
    final len = bytes[pos];
    if (len < 1 || pos + 1 + len > endPos) return const [];
    if (bytes.getRange(pos + 1, pos + 1 + len).any((c) => c < 0x20 || c >= 0x7f)) return const [];
    out.add(String.fromCharCodes(bytes, pos + 1, pos + 1 + len));
    pos += 1 + len;
  }
  return out;
}

List<ViType> clusterFields(ViType c, List<ViType> types) => [
  for (final member in c.members)
    if (member < types.length) types[member],
];

String typeLabel(ViType t, List<ViType> types) {
  final ei = t.elementIndex;
  if (t.kind == ViDataType.array && ei != null && ei < types.length) {
    return 'array<${types[ei].kind.name}>';
  }
  return t.kind.name;
}

String? _trailingName(Uint8List bytes, int start, int end) {
  for (final nameEnd in [end, end - 1]) {
    if (nameEnd <= start) continue;
    for (var len = 2; len <= 63; len++) {
      final lenPos = nameEnd - len - 1;
      if (lenPos < start) break;
      if (bytes[lenPos] != len) continue;
      var ok = true;
      var letters = 0;
      for (var i = lenPos + 1; i < nameEnd; i++) {
        final byte = bytes[i];
        if (byte < 0x20 || byte >= 0x7f) {
          ok = false;
          break;
        }
        if ((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)) letters++;
      }
      if (ok && (letters >= 2 || letters * 2 >= len)) {
        return String.fromCharCodes(bytes.sublist(lenPos + 1, nameEnd));
      }
    }
  }
  return null;
}

int _nameRegionStart(
  Uint8List bytes,
  int off,
  ViDataType kind,
  List<int> members,
  int? elementIndex,
  List<String> enumItems,
) {
  if (kind == ViDataType.cluster && members.isNotEmpty) {
    return off + 6 + members.length * 2;
  }
  if (kind == ViDataType.array && elementIndex != null) {
    final numDims = (bytes[off + 4] << 8) | bytes[off + 5];
    return off + 6 + numDims * 4 + 2;
  }
  if (enumItems.isNotEmpty) {
    return off + 6 + enumItems.fold<int>(0, (s, it) => s + 1 + it.length);
  }
  return off + 4;
}

Uint8List? reserializeTypePool(Uint8List body) {
  if (body.length < 6) return null;
  final count = (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
  if (count <= 0 || count > 200000) return null;
  final out = Uint8List(body.length);
  final view = ByteData.sublistView(out);
  view.setUint32(0, count);
  var off = 4;
  for (var i = 0; i < count; i++) {
    if (off + 4 > body.length) return null;
    final descLen = (body[off] << 8) | body[off + 1];
    if (descLen < 4 || off + descLen > body.length) return null;
    view.setUint16(off, descLen);
    out.setRange(off + 2, off + descLen, body, off + 2);
    off += descLen;
  }
  if (off + 2 > body.length) return null;
  final tlCount = (body[off] << 8) | body[off + 1];
  if (off + 2 + tlCount * 2 != body.length) return null;
  view.setUint16(off, tlCount);
  for (var e = 0; e < tlCount; e++) {
    final p = off + 2 + e * 2;
    view.setUint16(p, (body[p] << 8) | body[p + 1]);
  }
  return out;
}

bool typePoolFrames(Uint8List body) {
  if (body.length < 6) return false;
  final count = (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
  if (count <= 0 || count > 200000) return false;
  var off = 4;
  for (var i = 0; i < count; i++) {
    if (off + 4 > body.length) return false;
    final descLen = (body[off] << 8) | body[off + 1];
    if (descLen < 4 || off + descLen > body.length) return false;
    off += descLen;
  }
  if (off + 2 > body.length) return false;
  final tlCount = (body[off] << 8) | body[off + 1];
  return off + 2 + tlCount * 2 == body.length;
}

List<ViType> typePoolFromDecoded(Iterable<DecodedSection> decoded) {
  for (final decodedSection in decoded) {
    if (decodedSection.tag == 'VCTP') return decodeTypePool(decodedSection.bytes);
  }
  return const [];
}

List<ViType> namedTypes(List<ViType> types) => [
  for (final type in types)
    if (type.name != null) type,
];

Map<String, int> typeKindHistogram(List<ViType> types) {
  final counts = <ViDataType, int>{};
  for (final type in types) {
    counts.update(type.kind, (n) => n + 1, ifAbsent: () => 1);
  }
  final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {for (final entry in entries) entry.key.name: entry.value};
}
