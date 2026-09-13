/// `VCTP` — the VI's type pool: every data type as a descriptor, then the list of top-level
/// types that the heaps, `TM80`, `CONP` and `DFDS` refer to by index.
///
/// A descriptor is a length word, a flag byte, a type code, a body whose shape the code
/// selects, and, when [ViTypeFlag.label] is set, a Pascal label padded to an even length.
/// The same descriptor grammar appears inline in `TM80` and `DTHP` and inside typedefs; the
/// inline forms predate the type pool and omit the property byte of numerics and enums.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of descriptors
/// 4       rest  descriptors                entry[count] count descriptors
///   +0    2     length                     u16      bytes of the descriptor
///   +2    1     flags                      u8       bit set, see ViTypeFlag
///   +3    1     typeCode                   u8       see TypeCode and ViDataType
///   +4    rest  body                       bytes    shape selected by typeCode, see the ViType
///                                                   subclasses
///   +4    rest  label                      pstr     after the body when flag 0x40 is set, padded
///                                                   to an even length
/// …       2     topLevelCount              u16      after the descriptors
/// …       rest  topLevelIndices            u16[topLevelCount] descriptor index of each top-level
///                                                             type
/// ```
///
/// [ViTypePool] is a view over the payload holding one [ViType] view per descriptor; the
/// [ViType] subclasses expose each body; [decodeTypePool] requires the descriptors and the
/// top-level list to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../decode.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of descriptors');
const _descLength = BlockField(0, 2, 'length', 'u16', 'bytes of the descriptor');
const _descFlags = BlockField(2, 1, 'flags', 'u8', 'bit set, see ViTypeFlag');
const _descCode = BlockField(3, 1, 'typeCode', 'u8', 'see TypeCode and ViDataType');
const _descBody = BlockField(4, null, 'body', 'bytes', 'shape selected by typeCode, see the ViType subclasses');
const _descLabel = BlockField(
  4,
  null,
  'label',
  'pstr',
  'after the body when flag 0x40 is set, padded to an even length',
);
const _descriptors = BlockField(
  4,
  null,
  'descriptors',
  'entry[count]',
  'count descriptors',
  entry: [_descLength, _descFlags, _descCode, _descBody, _descLabel],
);
const _topLevelCount = BlockField(4, 2, 'topLevelCount', 'u16', 'after the descriptors');
const _topLevelIndices = BlockField(
  6,
  null,
  'topLevelIndices',
  'u16[topLevelCount]',
  'descriptor index of each top-level type',
);

const BlockLayout vctpLayout = [_count, _descriptors, _topLevelCount, _topLevelIndices];

/// Bits of a descriptor's flag byte.
enum ViTypeFlag {
  /// `0x40`: a Pascal label follows the body.
  label(0x40)
  ;

  const ViTypeFlag(this.mask);

  final int mask;
}

/// The data type a descriptor's type code names.
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

/// The type codes at descriptor offset 3.
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

const int _descriptorHead = 4;

/// One type descriptor: a view over [bytes] from [offset] for [length] bytes.
///
/// Subclasses expose the body their type code selects. Bytes between the decoded body and
/// the label, or to the end for codes whose body is not decoded, are [undecoded].
sealed class ViType {
  ViType._(this.bytes, this.offset, this.length, int bodyEnd, {bool exact = true})
    : _bodyEnd = bodyEnd,
      _labelStart = _findLabel(bytes, offset, length, bodyEnd, exact);

  final Uint8List bytes;

  final int offset;

  /// The descriptor's extent; for a typedef's inline base this is the remaining bytes, not
  /// the base's own length word.
  final int length;

  final int _bodyEnd;

  final int _labelStart;

  int get end => offset + length;

  /// The length word at offset 0, which for a typedef's inline base differs from [length].
  int get declaredLength => ByteData.sublistView(bytes).getUint16(offset + _descLength.offset);

  int get flags => bytes[offset + _descFlags.offset];

  int get code => bytes[offset + _descCode.offset];

  ViDataType get kind => _typeCodes[code] ?? ViDataType.unknown;

  bool get hasLabel => flags & ViTypeFlag.label.mask != 0;

  String? get label =>
      hasLabel ? String.fromCharCodes(bytes, _labelStart + 1, _labelStart + 1 + bytes[_labelStart]) : null;

  /// Bytes the grammar does not cover; empty for codes whose body is fully decoded.
  Uint8List get undecoded => Uint8List.sublistView(bytes, _bodyEnd, _labelStart);

  Uint8List get descriptorBytes => Uint8List.sublistView(bytes, offset, end);

  static bool _labelEndsAt(Uint8List bytes, int at, int end) {
    final n = bytes[at];
    return at + 1 + n + ((1 + n) & 1) == end;
  }

  static int _findLabel(Uint8List bytes, int offset, int length, int bodyEnd, bool exact) {
    final end = offset + length;
    assert(bodyEnd <= end, 'the body lies inside the descriptor');
    if (bytes[offset + _descFlags.offset] & ViTypeFlag.label.mask == 0) {
      assert(!exact || bodyEnd == end, 'an unlabelled descriptor ends with its body');
      return end;
    }
    if (exact) {
      assert(bodyEnd < end && _labelEndsAt(bytes, bodyEnd, end), 'the label follows the body and ends the descriptor');
      return bodyEnd;
    }
    for (var at = end - 1; at >= bodyEnd; at--) {
      if (_labelEndsAt(bytes, at, end)) return at;
    }
    assert(false, 'a labelled descriptor ends with its Pascal label');
    return end;
  }

  /// The descriptor at [offset] whose extent is [length]; [legacy] selects the inline grammar
  /// of `TM80` and `DTHP`, without the property byte after numerics and enum items.
  static ViType at(Uint8List bytes, int offset, int length, {bool legacy = false}) {
    assert(length >= _descriptorHead && offset + length <= bytes.length, 'a descriptor has its head inside the bytes');
    final view = ByteData.sublistView(bytes);
    final body = offset + _descriptorHead;
    switch (bytes[offset + _descCode.offset]) {
      case TypeCode.voidType:
        return ViVoidType._(bytes, offset, length, body);
      case >= TypeCode.i8 && <= TypeCode.complexExt:
        return ViNumericType._(bytes, offset, length, legacy ? body : body + 1);
      case >= TypeCode.enumU8 && <= TypeCode.enumU32:
        return ViEnumType._(bytes, offset, length, view, hasProperty: !legacy);
      case >= TypeCode.unitSgl && <= TypeCode.unitComplexExt:
        return ViUnitType._(bytes, offset, length, body);
      case TypeCode.booleanU16 || TypeCode.boolean:
        return ViBooleanType._(bytes, offset, length, body);
      case TypeCode.string || TypeCode.path || TypeCode.picture || TypeCode.subString:
        return ViStringType._(bytes, offset, length, body + 4);
      case TypeCode.cString:
        return ViStringType._(bytes, offset, length, body);
      case TypeCode.tag:
        return ViTagType._(bytes, offset, length, body + 6);
      case TypeCode.array || TypeCode.arrayDataPointer || TypeCode.subArray:
        return ViArrayType._(bytes, offset, length, body + 4 + 4 * view.getUint16(body));
      case TypeCode.cluster:
        return ViClusterType._(bytes, offset, length, body + 2 + 2 * view.getUint16(body));
      case TypeCode.variant:
        return ViVariantType._(bytes, offset, length, body);
      case TypeCode.measureData:
        return ViMeasureDataType._(bytes, offset, length, body + 2);
      case TypeCode.refnum:
        return ViRefnumType._(bytes, offset, length, body + 2);
      case TypeCode.ptr:
        return ViPointerType._(bytes, offset, length, body);
      case TypeCode.ptrTo:
        return ViPointerType._(bytes, offset, length, body + 2);
      case TypeCode.function:
        return ViFunctionType._(bytes, offset, length, body + 2 + 2 * view.getUint16(body));
      case TypeCode.typeDef:
        return ViTypedefType._(bytes, offset, length, legacy: legacy);
      case TypeCode.polyVi:
        return ViPolyViType._(bytes, offset, length, body + 4);
      default:
        return ViUnknownType._(bytes, offset, length, body);
    }
  }
}

/// `0x00`: no body.
final class ViVoidType extends ViType {
  ViVoidType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();
}

/// `0x01`–`0x0e`: a numeric scalar with one property byte, absent in the inline grammar.
final class ViNumericType extends ViType {
  ViNumericType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  /// The body byte; role TODO. Null in the inline grammar.
  int? get property => _bodyEnd > offset + _descriptorHead ? bytes[offset + _descriptorHead] : null;
}

/// `0x15`–`0x17`: an enumeration: a count of Pascal items padded to an even length, then one
/// property byte, absent in the inline grammar.
final class ViEnumType extends ViType {
  ViEnumType._(Uint8List bytes, int offset, int length, ByteData view, {required bool hasProperty})
    : _itemOffsets = _items(bytes, offset, length, view),
      _hasProperty = hasProperty,
      super._(bytes, offset, length, _itemsEnd(bytes, offset, length, view) + (hasProperty ? 1 : 0));

  final List<int> _itemOffsets;

  final bool _hasProperty;

  int get itemCount => _itemOffsets.length;

  String itemAt(int index) {
    final at = _itemOffsets[index];
    return String.fromCharCodes(bytes, at + 1, at + 1 + bytes[at]);
  }

  List<String> get items => [for (var i = 0; i < itemCount; i++) itemAt(i)];

  /// The byte after the items; role TODO. Null in the inline grammar.
  int? get property => _hasProperty ? bytes[_bodyEnd - 1] : null;

  static List<int> _items(Uint8List bytes, int offset, int length, ByteData view) {
    final body = offset + _descriptorHead;
    final count = view.getUint16(body);
    assert(count <= length, 'the item count fits the descriptor');
    final offsets = List<int>.filled(count, 0);
    var at = body + 2;
    for (var i = 0; i < count; i++) {
      assert(at < offset + length, 'item $i has a length byte');
      offsets[i] = at;
      at += 1 + bytes[at];
    }
    return offsets;
  }

  static int _itemsEnd(Uint8List bytes, int offset, int length, ByteData view) {
    final body = offset + _descriptorHead;
    var at = body + 2;
    for (var i = view.getUint16(body); i > 0; i--) {
      at += 1 + bytes[at];
    }
    return at + ((at - body) & 1);
  }
}

/// `0x19`–`0x1e`: a numeric with units; body not decoded.
final class ViUnitType extends ViType {
  ViUnitType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._(exact: false);
}

/// `0x20`, `0x21`: no body.
final class ViBooleanType extends ViType {
  ViBooleanType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();
}

/// `0x30` string, `0x32` path, `0x33` picture, `0x3f` substring: a maximum length word;
/// `0x34` C string: no body.
final class ViStringType extends ViType {
  ViStringType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  /// `0xFFFFFFFF` when unbounded; null for a C string.
  int? get maxLength =>
      code == TypeCode.cString ? null : ByteData.sublistView(bytes).getUint32(offset + _descriptorHead);
}

/// `0x37`: a tag: a maximum length word and a tag kind, then a body not decoded.
final class ViTagType extends ViType {
  ViTagType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._(exact: false);

  int get tagKind => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead + 4);
}

/// `0x40` array, `0x41` array data pointer, `0x4f` subarray: a dimension count, one size word
/// per dimension (`0xFFFFFFFF` when variable) and the element's pool index.
final class ViArrayType extends ViType {
  ViArrayType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  int get dimCount => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead);

  int dimSizeAt(int dim) => ByteData.sublistView(bytes).getUint32(offset + _descriptorHead + 2 + 4 * dim);

  int get elementIndex => ByteData.sublistView(bytes).getUint16(_bodyEnd - 2);
}

/// `0x50`: a cluster: a member count and one pool index per member.
final class ViClusterType extends ViType {
  ViClusterType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  int get memberCount => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead);

  int memberIndexAt(int index) => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead + 2 + 2 * index);

  List<int> get memberIndices => [for (var i = 0; i < memberCount; i++) memberIndexAt(i)];
}

/// `0x53`: no body.
final class ViVariantType extends ViType {
  ViVariantType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();
}

/// `0x54`: measurement data with a flavor word.
final class ViMeasureDataType extends ViType {
  ViMeasureDataType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  int get flavor => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead);
}

/// `0x70`: a reference with a kind word, then a body not decoded.
final class ViRefnumType extends ViType {
  ViRefnumType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._(exact: false);

  int get refKind => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead);
}

/// `0x80` pointer: no body; `0x83` pointer to a pool index.
final class ViPointerType extends ViType {
  ViPointerType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  /// Null for `0x80`.
  int? get targetIndex =>
      code == TypeCode.ptrTo ? ByteData.sublistView(bytes).getUint16(offset + _descriptorHead) : null;
}

/// `0xf0`: a function: a parameter count and one pool index per parameter, then a body not
/// decoded.
final class ViFunctionType extends ViType {
  ViFunctionType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._(exact: false);

  int get parameterCount => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead);

  int parameterIndexAt(int index) => ByteData.sublistView(bytes).getUint16(offset + _descriptorHead + 2 + 2 * index);
}

/// `0xf1`: a typedef: an id word, a count of Pascal path components, then the base
/// descriptor inline to the end; its length word is not its extent.
final class ViTypedefType extends ViType {
  ViTypedefType._(Uint8List bytes, int offset, int length, {required bool legacy})
    : _componentOffsets = _components(bytes, offset, length),
      _legacy = legacy,
      super._(bytes, offset, length, offset + length);

  final List<int> _componentOffsets;

  final bool _legacy;

  int get id => ByteData.sublistView(bytes).getUint32(offset + _descriptorHead);

  int get componentCount => _componentOffsets.length;

  String componentAt(int index) {
    final at = _componentOffsets[index];
    return String.fromCharCodes(bytes, at + 1, at + 1 + bytes[at]);
  }

  int get _baseOffset => _componentOffsets.isEmpty
      ? offset + _descriptorHead + 8
      : _componentOffsets.last + 1 + bytes[_componentOffsets.last];

  ViType get base => ViType.at(bytes, _baseOffset, end - _baseOffset, legacy: _legacy);

  /// The base's label: a typedef carries no label of its own.
  @override
  String? get label => hasLabel ? super.label : base.label;

  static List<int> _components(Uint8List bytes, int offset, int length) {
    final view = ByteData.sublistView(bytes);
    assert(length >= _descriptorHead + 8, 'a typedef has its id and component count');
    final count = view.getUint32(offset + _descriptorHead + 4);
    assert(count <= length, 'the component count fits the descriptor');
    final offsets = List<int>.filled(count, 0);
    var at = offset + _descriptorHead + 8;
    for (var i = 0; i < count; i++) {
      assert(at < offset + length, 'component $i has a length byte');
      offsets[i] = at;
      at += 1 + bytes[at];
    }
    assert(at + _descriptorHead <= offset + length, 'the inline base follows the components');
    return offsets;
  }
}

/// `0xf2`: a polymorphic VI reference with an id word.
final class ViPolyViType extends ViType {
  ViPolyViType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._();

  int get id => ByteData.sublistView(bytes).getUint32(offset + _descriptorHead);
}

/// A type code with no decoded body: fixed point, blocks and codes not named by [TypeCode].
final class ViUnknownType extends ViType {
  ViUnknownType._(super.bytes, super.offset, super.length, super.bodyEnd) : super._(exact: false);
}

/// The offsets of [count] consecutive descriptors starting at [start], each sized by its
/// length word.
List<int> descriptorOffsets(Uint8List bytes, int start, int count) {
  final view = ByteData.sublistView(bytes);
  assert(count <= (bytes.length - start) ~/ _descriptorHead, 'the descriptor count fits the bytes');
  final offsets = List<int>.filled(count, 0);
  var at = start;
  for (var i = 0; i < count; i++) {
    assert(at + _descriptorHead <= bytes.length, 'descriptor $i has its head');
    final length = view.getUint16(at + _descLength.offset);
    assert(length >= _descriptorHead && at + length <= bytes.length, 'descriptor $i lies inside the bytes');
    offsets[i] = at;
    at += length;
  }
  return offsets;
}

/// A view over a `VCTP` payload.
class ViTypePool {
  ViTypePool._(this.bytes, this.types, this._topLevelOffset) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  /// One view per descriptor, in pool order.
  final List<ViType> types;

  final int _topLevelOffset;

  int get length => types.length;

  ViType operator [](int index) => types[index];

  int get topLevelCount => _view.getUint16(_topLevelOffset);

  /// The pool index of the top-level type at [index].
  int topLevelIndexAt(int index) => _view.getUint16(_topLevelOffset + 2 + 2 * index);

  List<int> get topLevelIndices => [for (var i = 0; i < topLevelCount; i++) topLevelIndexAt(i)];

  Uint8List serialize() => bytes;
}

/// Whether [bytes] frame as a type pool: the count, each descriptor's length word and the
/// top-level list tile the payload. [decodeTypePool] additionally requires every descriptor
/// body and label to be well formed.
bool typePoolFrames(Uint8List bytes) {
  if (bytes.length < _count.end + 2) return false;
  final view = ByteData.sublistView(bytes);
  var at = _descriptors.offset;
  for (var i = view.getUint32(_count.offset); i > 0; i--) {
    if (at + _descriptorHead > bytes.length) return false;
    final length = view.getUint16(at + _descLength.offset);
    if (length < _descriptorHead) return false;
    at += length;
  }
  return at + 2 <= bytes.length && at + 2 + 2 * view.getUint16(at) == bytes.length;
}

ViTypePool decodeTypePool(Uint8List bytes) {
  assert(bytes.length >= _count.end + 2, 'a type pool holds its count and the top-level count');
  final view = ByteData.sublistView(bytes);
  final offsets = descriptorOffsets(bytes, _descriptors.offset, view.getUint32(_count.offset));
  final types = [
    for (var i = 0; i < offsets.length; i++)
      ViType.at(bytes, offsets[i], view.getUint16(offsets[i] + _descLength.offset)),
  ];
  final topLevelOffset = offsets.isEmpty ? _descriptors.offset : types.last.end;
  assert(topLevelOffset + 2 <= bytes.length, 'the top-level count follows the descriptors');
  assert(
    topLevelOffset + 2 + 2 * view.getUint16(topLevelOffset) == bytes.length,
    'the top-level indices tile the payload',
  );
  return ViTypePool._(bytes, types, topLevelOffset);
}

ViTypePool? typePoolFromDecoded(Iterable<DecodedSection> decoded) {
  for (final decodedSection in decoded) {
    if (decodedSection.tag == 'VCTP') return decodeTypePool(decodedSection.bytes);
  }
  return null;
}

int? serializedDefaultSize(ViType t, List<ViType> pool, [int depth = 0]) {
  if (depth > 64) return null;
  switch (t) {
    case ViVoidType():
      return 0;
    case ViNumericType() || ViBooleanType():
      return switch (t.code) {
        TypeCode.i8 || TypeCode.u8 || TypeCode.boolean => 1,
        TypeCode.i16 || TypeCode.u16 => 2,
        TypeCode.i32 || TypeCode.u32 || TypeCode.sgl => 4,
        TypeCode.i64 || TypeCode.u64 || TypeCode.dbl || TypeCode.complexSgl => 8,
        TypeCode.ext || TypeCode.complexDbl => 16,
        TypeCode.complexExt => 32,
        _ => null,
      };
    case ViEnumType():
      return switch (t.code) {
        TypeCode.enumU8 => 1,
        TypeCode.enumU16 => 2,
        _ => 4,
      };
    case ViRefnumType():
      return 4;
    case ViClusterType():
      if (t.memberCount == 0) return null;
      var total = 0;
      for (var i = 0; i < t.memberCount; i++) {
        final m = t.memberIndexAt(i);
        if (m >= pool.length) return null;
        final s = serializedDefaultSize(pool[m], pool, depth + 1);
        if (s == null) return null;
        total += s;
      }
      return total;
    case ViTypedefType():
      return serializedDefaultSize(t.base, pool, depth + 1);
    default:
      return null;
  }
}

const int kDataSpaceInitTableBytes = 51 * 4;

List<ViType> clusterFields(ViType c, List<ViType> types) => switch (c) {
  ViClusterType() => [
    for (var i = 0; i < c.memberCount; i++)
      if (c.memberIndexAt(i) < types.length) types[c.memberIndexAt(i)],
  ],
  _ => const [],
};

String typeLabel(ViType t, List<ViType> types) {
  if (t case ViArrayType(:final elementIndex) when elementIndex < types.length) {
    return 'array<${types[elementIndex].kind.name}>';
  }
  return t.kind.name;
}

List<ViType> namedTypes(List<ViType> types) => [
  for (final type in types)
    if (type.label != null) type,
];

Map<String, int> typeKindHistogram(List<ViType> types) {
  final counts = <ViDataType, int>{};
  for (final type in types) {
    counts.update(type.kind, (n) => n + 1, ifAbsent: () => 1);
  }
  final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {for (final entry in entries) entry.key.name: entry.value};
}
