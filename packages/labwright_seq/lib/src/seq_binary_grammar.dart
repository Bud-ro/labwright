/// Record grammar of the inflated `TOF1` body.
///
/// Every multi-byte integer is little endian and the stream is not aligned: a `u8` field shifts
/// everything after it by one byte. Strings are indices into the NUL-separated pool that follows the
/// record region; the index `0xffffffff` ([binaryNullIndex]) is the null string.
///
/// ```text
/// body
///   u32                 typeCount
///   TypeEntry[typeCount]
///   Record              data root, class SequenceFileData (Obj in TestStand 4.x), name Data
///   u32                 tailWord              TODO: zero in every corpus file, purpose not yet decoded
///   u32                 0xffffffff
///   u32                 poolCount
///   cstr[poolCount]     pool, NUL terminated, unique, Latin-1
///
/// TypeEntry
///   u32                 entryFlags            BinaryPropertyFlag bits; typeFlags (0x10) gates the typeflags word
///   u32                 entryWord             TODO: 1 in every corpus file, purpose not yet decoded
///   u32                 class                 pool index
///   u32                 name                  pool index
///   ValuePart           bounds/elemproto for array classes, enum items and value for Enum
///   u32?                comment               pool index, when entryFlags & comment
///   u32                 typeCategory          1 step type, 2 custom data type, 3 built-in type
///   u32                 timestamp             seconds since 1970
///   u32                 timestampHigh         ts2014 and later only; zero in every corpus file
///   u32                 typeVersion           pool index
///   u32                 typeLastModVersion    pool index
///   u32                 typeMinProdVersion    pool index
///   u32?                typeFlags             when entryFlags & typeFlags
///   Attrs               flagsForInstances / instanceOverrideFlags / valueFlags words per entryFlags
///   u32                 hasProtectionDigest   ts2013 and later; 1 for types the XML writer emits as <protected>
///   u32                 protectionDigest      pool index or null
///   u32                 hasSecondaryDigest    ts2013 and later
///   u32?                secondaryDigest       pool index, when hasSecondaryDigest
///   ExtData?            when entryFlags & extData
///   Record?             attributes, when entryFlags & attributes
///   Record?             typeAttributes, when entryFlags & typeAttributes
///   u32                 childCount
///   Record[childCount]
///   u32                 additionalTypeFlags
///   u8                  alwaysSaveType
///   u32                 typelistOrderNum
///
/// Record
///   u32                 flags                 BinaryPropertyFlag bits
///   u32                 flagsHigh             TODO: zero in every corpus file; not yet decoded
///   u32                 class                 pool index, or null to inherit the class from the type
///   u32?                typeRef               index into the type table, when flags & typed
///   u32                 name                  pool index, null for array elements and elemprotos
///   ValuePart
///   u32?                comment               pool index, when flags & comment
///   u32?                numericFormat         pool index, when flags & numericFormat
///   u32?                flagsForInstances     when flags & flagsForInstances
///   u32?                instanceOverrideFlags when flags & instanceOverrideFlags
///   u32?                valueFlags            when flags & (valueFlags | structureFlags)
///   ExtData?            when flags & extData
///   Record?             attributes, when flags & attributes
///   Record?             typeAttributes, when flags & typeAttributes
///   u32                 childCount
///   Record[childCount]
///
/// ValuePart, by class
///   Num                 u32? representation (flags & numericRepresentation); f64 or i64/u64 value (flags & value)
///   Str/ExprValue/Path  u32? value pool index (flags & value)
///   Bool                u8? value (flags & value)
///   Ref                 nothing; the value bit carries no payload
///   Nums/Strs/Bools/Refs u32 lbound, u32 ubound (pool indices like '[0]' '[3]'), then one f64/u32/u8/u32 per element
///   Objs/Containers     u32 lbound, u32 ubound, u8 hasElemProto, Record? elemproto, Record[elements]
///   Enum                flags & enumItems: u32 itemsWord (TODO: 1 in every corpus file), Record items (an Objs array)
///                       flags & enumValue: u32 enumerator name pool index, f64 enumerator value
///   other               nothing; the record is a container
///
/// ExtData
///   u32                 count
///   per entry: u32 controller pool index, then
///     STRUCT            u8 allowStructPassing, u32 packingOption, u8 exclude, u32 type, u32 arrayStorage,
///                       u32 strBufferSize, u32 strStorage
///     CLUST/BLVCLUSTER  u8 allowClusterPassing, u8 exclude, u32 memberLabel
///     DNSTRUCT          u8 allowStructPassing, u8 exclude, u32 memberName
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'seq_binary_header.dart';
import 'seq_property.dart';

/// Pool index of the null string, also the class slot of a record that inherits its class from its type.
const binaryNullIndex = 0xffffffff;

/// Bits of a record's flags word (and of a typedef entry's flags word).
enum BinaryPropertyFlag {
  /// A comment pool index follows the value part.
  comment(0x1),

  /// The value part is present (always set on arrays; carries no payload for `Ref`).
  value(0x2),

  /// The valueflags word is present; XML emits it as `valueflags` (the word masked by [structureFlagMask]'s complement).
  valueFlags(0x4),

  /// The valueflags word is present; XML emits the bits in [structureFlagMask] as `structureflags`.
  structureFlags(0x8),

  /// Typedef entries only: the typeflags word follows the version triple.
  typeFlags(0x10),

  /// A `flagsforinstances` word follows.
  flagsForInstances(0x20),

  /// An `instanceoverrideflags` word follows.
  instanceOverrideFlags(0x40),

  /// A type-table index follows the class slot.
  typed(0x80),

  /// An ExtData block follows the attribute words.
  extData(0x100),

  /// A numeric-format pool index follows the value (XML `<numericfmt>`).
  numericFormat(0x200),

  /// A representation word precedes a `Num` value (2 = Int64, 3 = UInt64).
  numericRepresentation(0x800),

  /// An `Attributes` record follows the ExtData block.
  attributes(0x1000),

  /// A `TypeAttributes` record follows the `Attributes` record.
  typeAttributes(0x4000),

  /// `Enum` only: the current enumerator name and value are present.
  enumValue(0x10000),

  /// `Enum` only: the items array is present.
  enumItems(0x20000);

  const BinaryPropertyFlag(this.bit);

  final int bit;

  static const int knownMask =
      0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80 | 0x100 | 0x200 | 0x800 | 0x1000 | 0x4000 | 0x10000 | 0x20000;

  bool isSetIn(int flags) => flags & bit != 0;
}

/// Bits of the valueflags word the XML writer reports as `structureflags` rather than `valueflags`.
///
/// TODO: only these three bits occur in the corpus; the full mask is not yet decoded.
const structureFlagMask = 0x20000 | 0x80000 | 0x200000;

/// Representation word of a `Num` whose value is stored as a 64-bit integer instead of a double.
enum BinaryNumericRepresentation {
  int64(2, 'Int64'),

  uint64(3, 'UInt64');

  const BinaryNumericRepresentation(this.code, this.xmlName);

  final int code;

  final String xmlName;

  static BinaryNumericRepresentation? of(int? code) => switch (code) {
    2 => int64,
    3 => uint64,
    _ => null,
  };
}

/// `extdata` controller names and their field layouts.
enum ExtDataController {
  /// C struct passing: `allowstructpassing`, `packingoption`, `exclude`, `type`, `arraystorage`, `strbuffersize`, `strstorage`.
  struct('STRUCT'),

  /// LabVIEW cluster passing: `allowclusterpassing`, `exclude`, `memberlabel`.
  cluster('CLUST'),

  /// .NET struct passing: `allowstructpassing`, `exclude`, `membername`.
  dotNetStruct('DNSTRUCT'),

  /// LabVIEW class/cluster passing: `allowclusterpassing`, `exclude`, `memberlabel`.
  lvCluster('BLVCLUSTER');

  const ExtDataController(this.controllerName);

  final String controllerName;

  static ExtDataController? byName(String name) {
    for (final controller in values) {
      if (controller.controllerName == name) return controller;
    }
    return null;
  }
}

final class BinaryExtData {
  BinaryExtData({
    required this.controller,
    required this.controllerIndex,
    required this.allowPassing,
    required this.exclude,
    this.packingOption,
    this.type,
    this.arrayStorage,
    this.strBufferSize,
    this.strStorage,
    this.memberIndex = binaryNullIndex,
    this.member,
  });

  final ExtDataController controller;

  final int controllerIndex;

  final bool allowPassing;

  final bool exclude;

  final int? packingOption;

  final int? type;

  final int? arrayStorage;

  final int? strBufferSize;

  final int? strStorage;

  final int memberIndex;

  final String? member;

  /// The entry as the attributes of an XML `<extdata>` element.
  Map<String, String> toXmlAttributes() {
    String flag(bool value) => value ? 'true' : 'false';
    return switch (controller) {
      ExtDataController.struct => {
        'controllername': controller.controllerName,
        'allowstructpassing': flag(allowPassing),
        'packingoption': '$packingOption',
        'exclude': flag(exclude),
        'type': '$type',
        'arraystorage': '$arrayStorage',
        'strbuffersize': '$strBufferSize',
        'strstorage': '$strStorage',
      },
      ExtDataController.cluster || ExtDataController.lvCluster => {
        'controllername': controller.controllerName,
        'allowclusterpassing': flag(allowPassing),
        'exclude': flag(exclude),
        'memberlabel': member ?? '',
      },
      ExtDataController.dotNetStruct => {
        'controllername': controller.controllerName,
        'allowstructpassing': flag(allowPassing),
        'exclude': flag(exclude),
        'membername': member ?? '',
      },
    };
  }
}

/// Per-byte classification of the inflated body.
enum BinaryByteTier {
  /// Bytes whose purpose is not yet decoded (constant words the grammar skips).
  undecoded,

  /// Framing: flag words, counts, null markers, indices that only locate other bytes.
  structural,

  /// Bytes carrying model content: names, classes, values, bounds, flags attributes, versions.
  semantic,

  /// The string pool.
  pool,
}

/// A thrown grammar violation, with the body offset where decoding stopped.
final class Tof1FormatException extends FormatException {
  Tof1FormatException(super.message, this.bodyOffset);

  final int bodyOffset;

  @override
  String toString() => 'Tof1FormatException: $message at body offset 0x${bodyOffset.toRadixString(16)}';
}

/// One property object of the record grammar: a typedef root, a subproperty, an array element or an elemproto.
final class BinaryRecord {
  BinaryRecord({
    required this.offset,
    required this.flags,
    required this.classIndex,
    required this.className,
    required this.typeRef,
    required this.nameIndex,
    required this.name,
  });

  final int offset;

  int end = 0;

  final int flags;

  /// Pool index of the explicit class, or [binaryNullIndex] when the class is inherited.
  final int classIndex;

  final String? className;

  final int? typeRef;

  final int nameIndex;

  final String? name;

  int commentIndex = binaryNullIndex;

  String? comment;

  int lboundIndex = binaryNullIndex;

  int uboundIndex = binaryNullIndex;

  String? lbound;

  String? ubound;

  bool hasElemProto = false;

  BinaryRecord? elemProto;

  /// Array elements: [BinaryRecord]s for object arrays, `double`, `int`, `String?` or `bool` for scalar arrays.
  List<Object?>? elements;

  /// Pool indices of a `Strs` array's elements.
  List<int>? elementIndices;

  int? representation;

  /// A `double`, an `int` (integer representations), a `String?` or a `bool`; null when no value is stored.
  Object? value;

  int valueIndex = binaryNullIndex;

  int formatIndex = binaryNullIndex;

  String? numericFormat;

  int? flagsForInstances;

  int? instanceOverrideFlags;

  int? valueFlagsWord;

  List<BinaryExtData> extData = const [];

  BinaryRecord? attributes;

  BinaryRecord? typeAttributes;

  int? enumItemsWord;

  BinaryRecord? enumItems;

  int enumValueIndex = binaryNullIndex;

  String? enumValueName;

  double? enumValue;

  List<BinaryRecord> children = const [];

  /// The class after inheritance through the type table.
  late String resolvedClassName;

  late SeqValueClass kind;

  /// The record this one instantiates: a typedef root, or the matching child of the parent's definition.
  BinaryRecord? definition;

  String? typeName;

  bool has(BinaryPropertyFlag flag) => flag.isSetIn(flags);

  bool get isArray => kind.isArray;

  bool get isEnum => kind == SeqValueClass.enumeration;

  bool get isLeaf => !isArray && !isEnum && kind.isLeaf;

  bool get isContainer => !isArray && !isEnum && !kind.isLeaf;

  /// `valueflags` as XML reports it: the word without the [structureFlagMask] bits.
  int? get valueFlags => has(BinaryPropertyFlag.valueFlags) ? valueFlagsWord! & ~structureFlagMask : null;

  /// `structureflags` as XML reports it: the [structureFlagMask] bits of the word.
  int? get structureFlags => has(BinaryPropertyFlag.structureFlags) ? valueFlagsWord! & structureFlagMask : null;

  BinaryRecord? child(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }

  @override
  String toString() =>
      'BinaryRecord(${name ?? '<unnamed>'}, $resolvedClassName'
      '${typeName != null ? ' <$typeName>' : ''}'
      '${value != null ? ' = $value' : ''}, ${children.length} children)';
}

/// One `typedef` of the type table.
final class BinaryTypeEntry {
  BinaryTypeEntry({
    required this.offset,
    required this.entryFlags,
    required this.entryWord,
    required this.root,
  });

  final int offset;

  final int entryFlags;

  /// TODO: 1 in every corpus file; purpose not yet decoded.
  final int entryWord;

  final BinaryRecord root;

  int category = 0;

  int timestamp = 0;

  int versionIndex = binaryNullIndex;

  int lastModVersionIndex = binaryNullIndex;

  int minProductVersionIndex = binaryNullIndex;

  String version = '';

  String lastModVersion = '';

  String minProductVersion = '';

  int? typeFlags;

  bool isProtected = false;

  int protectionDigestIndex = binaryNullIndex;

  /// TODO: an obfuscated digest carried by protected types; its derivation is not yet decoded.
  String? protectionDigest;

  bool hasSecondaryDigest = false;

  int secondaryDigestIndex = binaryNullIndex;

  /// TODO: a second digest some protected types carry; its derivation is not yet decoded.
  String? secondaryDigest;

  int additionalTypeFlags = 0;

  bool alwaysSaveType = false;

  int orderNumber = 0;

  int end = 0;

  String get name => root.name ?? '';

  /// The typedef header as XML `typedef` child-element attributes.
  Map<String, String> toXmlAttributes() => {
    'isroottypedef': 'true',
    'typecategory': '$category',
    'timestamp': '$timestamp',
    'typeversion': version,
    'typelastmodversion': lastModVersion,
    'typeminprodversion': minProductVersion,
    if (typeFlags != null) 'typeflags': '$typeFlags',
  };

  /// The entry as the attributes of its XML `<typedef>` wrapper.
  Map<String, String> toXmlEntryAttributes() => {
    'alwayssavetype': alwaysSaveType ? 'true' : 'false',
    'additionaltypeflags': '$additionalTypeFlags',
    'typelistordernum': '$orderNumber',
  };
}

/// The decoded body: the type table, the data root, the pool and every byte's tier.
final class Tof1Body {
  Tof1Body({
    required this.bytes,
    required this.generation,
    required this.recordRegionLength,
    required this.types,
    required this.data,
    required this.tailWord,
    required this.pool,
    required this.poolOffsets,
    required this.tiers,
  });

  final Uint8List bytes;

  final Tof1Generation generation;

  /// Offset of the pool count word; also the length of the record region.
  final int recordRegionLength;

  final List<BinaryTypeEntry> types;

  final BinaryRecord data;

  /// TODO: zero in every corpus file; purpose not yet decoded.
  final int tailWord;

  final List<String> pool;

  /// Body offset of each pool string's first byte.
  final List<int> poolOffsets;

  /// [BinaryByteTier] per body byte.
  final Uint8List tiers;
}

const _u32 = 4;

const _f64 = 8;

const _minRecordBytes = 5 * _u32;

const _maxDepth = 200;

const _maxExtData = 64;

/// Splits the pool region into strings; `offsets` receives each string's body offset.
List<String> binaryPoolStrings(Uint8List body, int poolOffset, int count, List<int> offsets) {
  final pool = <String>[];
  var at = poolOffset;
  while (pool.length < count && at < body.length) {
    final start = at;
    while (at < body.length && body[at] != 0) {
      at++;
    }
    offsets.add(start);
    pool.add(decodePoolString(body, start, at));
    at++;
  }
  return pool;
}

/// Pool strings are Latin-1 where they are not valid UTF-8.
String decodePoolString(Uint8List body, int start, int end) {
  var ascii = true;
  for (var i = start; i < end; i++) {
    if (body[i] >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(body, start, end);
  final slice = Uint8List.sublistView(body, start, end);
  try {
    return utf8.decode(slice);
  } on FormatException {
    return latin1.decode(slice);
  }
}

/// Decodes an inflated body; throws [Tof1FormatException] where the bytes leave the grammar.
Tof1Body parseTof1Body(Uint8List body, {required int recordRegionLength, required Tof1Generation generation}) =>
    _Tof1BodyParser(body, recordRegionLength, generation).parse();

final class _Tof1BodyParser {
  _Tof1BodyParser(this.body, this.recordRegionLength, this.generation)
    : view = ByteData.sublistView(body),
      tiers = Uint8List(body.length);

  final Uint8List body;

  final ByteData view;

  final int recordRegionLength;

  final Tof1Generation generation;

  final Uint8List tiers;

  late final List<String> pool;

  late final List<int> poolOffsets;

  final List<BinaryTypeEntry> types = [];

  int at = 0;

  Tof1Body parse() {
    final poolCountAt = recordRegionLength;
    if (recordRegionLength < 2 * _u32 || poolCountAt + _u32 > body.length) {
      throw Tof1FormatException('record region length $recordRegionLength does not fit the body', 0);
    }
    final poolCount = view.getUint32(poolCountAt, Endian.little);
    poolOffsets = <int>[];
    pool = binaryPoolStrings(body, poolCountAt + _u32, poolCount, poolOffsets);
    if (pool.length != poolCount) {
      throw Tof1FormatException('pool count $poolCount but ${pool.length} strings follow', poolCountAt);
    }
    _mark(poolCountAt, _u32, BinaryByteTier.structural);
    _mark(poolCountAt + _u32, body.length - poolCountAt - _u32, BinaryByteTier.pool);

    final typeCount = _u32s(BinaryByteTier.structural);
    if (typeCount > recordRegionLength ~/ _minRecordBytes) {
      throw Tof1FormatException('type count $typeCount exceeds the record region', at - _u32);
    }
    for (var i = 0; i < typeCount; i++) {
      _typeEntry();
    }
    final data = _record(0, null);
    final tailWord = _u32s(BinaryByteTier.undecoded);
    final sentinel = _u32s(BinaryByteTier.structural);
    if (sentinel != binaryNullIndex) {
      throw Tof1FormatException('expected the 0xffffffff sentinel before the pool count', at - _u32);
    }
    if (at != recordRegionLength) {
      throw Tof1FormatException(
        'record region ends at 0x${at.toRadixString(16)}, pool count at 0x${recordRegionLength.toRadixString(16)}',
        at,
      );
    }
    return Tof1Body(
      bytes: body,
      generation: generation,
      recordRegionLength: recordRegionLength,
      types: types,
      data: data,
      tailWord: tailWord,
      pool: pool,
      poolOffsets: poolOffsets,
      tiers: tiers,
    );
  }

  void _mark(int start, int length, BinaryByteTier tier) {
    final end = start + length;
    for (var i = start; i < end; i++) {
      tiers[i] = tier.index;
    }
  }

  void _need(int bytes) {
    if (at + bytes > recordRegionLength) {
      throw Tof1FormatException('record region ends inside a field', at);
    }
  }

  int _u32s(BinaryByteTier tier) {
    _need(_u32);
    final value = view.getUint32(at, Endian.little);
    _mark(at, _u32, tier);
    at += _u32;
    return value;
  }

  int _u8s(BinaryByteTier tier) {
    _need(1);
    final value = body[at];
    tiers[at] = tier.index;
    at += 1;
    return value;
  }

  double _f64s() {
    _need(_f64);
    final value = view.getFloat64(at, Endian.little);
    _mark(at, _f64, BinaryByteTier.semantic);
    at += _f64;
    return value;
  }

  int _i64s(bool signed) {
    _need(_f64);
    final value = signed ? view.getInt64(at, Endian.little) : view.getUint64(at, Endian.little);
    _mark(at, _f64, BinaryByteTier.semantic);
    at += _f64;
    return value;
  }

  /// Reads a pool index; null strings decode to null.
  int _strIndex(BinaryByteTier tier) {
    final index = _u32s(tier);
    if (index != binaryNullIndex && index >= pool.length) {
      throw Tof1FormatException('pool index $index beyond the ${pool.length}-string pool', at - _u32);
    }
    return index;
  }

  String? _str(int index) => index == binaryNullIndex ? null : pool[index];

  void _checkFlags(int flags, int offset) {
    if (flags & ~BinaryPropertyFlag.knownMask != 0) {
      throw Tof1FormatException(
        'flag bits 0x${(flags & ~BinaryPropertyFlag.knownMask).toRadixString(16)} not yet decoded',
        offset,
      );
    }
  }

  BinaryTypeEntry _typeEntry() {
    final offset = at;
    final entryFlags = _u32s(BinaryByteTier.structural);
    _checkFlags(entryFlags, offset);
    final entryWord = _u32s(BinaryByteTier.undecoded);
    final classIndex = _strIndex(BinaryByteTier.semantic);
    if (classIndex == binaryNullIndex) throw Tof1FormatException('a typedef needs an explicit class', at - _u32);
    final nameIndex = _strIndex(BinaryByteTier.semantic);
    final root = BinaryRecord(
      offset: offset + 2 * _u32,
      flags: entryFlags,
      classIndex: classIndex,
      className: pool[classIndex],
      typeRef: null,
      nameIndex: nameIndex,
      name: _str(nameIndex),
    );
    root.resolvedClassName = pool[classIndex];
    root.kind = SeqValueClass.from(root.resolvedClassName);
    final entry = BinaryTypeEntry(offset: offset, entryFlags: entryFlags, entryWord: entryWord, root: root);
    types.add(entry);
    _valuePart(root, root.isArray ? entryFlags | BinaryPropertyFlag.value.bit : entryFlags, 1, null);
    if (BinaryPropertyFlag.comment.isSetIn(entryFlags)) {
      root.commentIndex = _strIndex(BinaryByteTier.semantic);
      root.comment = _str(root.commentIndex);
    }
    entry.category = _u32s(BinaryByteTier.semantic);
    entry.timestamp = _u32s(BinaryByteTier.semantic);
    if (generation.hasWideTimestamp) {
      final high = _u32s(BinaryByteTier.semantic);
      if (high != 0) throw Tof1FormatException('type timestamp high word $high', at - _u32);
    }
    entry.versionIndex = _strIndex(BinaryByteTier.semantic);
    entry.lastModVersionIndex = _strIndex(BinaryByteTier.semantic);
    entry.minProductVersionIndex = _strIndex(BinaryByteTier.semantic);
    entry.version = _str(entry.versionIndex) ?? '';
    entry.lastModVersion = _str(entry.lastModVersionIndex) ?? '';
    entry.minProductVersion = _str(entry.minProductVersionIndex) ?? '';
    if (BinaryPropertyFlag.typeFlags.isSetIn(entryFlags)) entry.typeFlags = _u32s(BinaryByteTier.semantic);
    _attributeWords(root, entryFlags);
    if (generation.hasProtectionBlock) {
      entry.isProtected = _flagWord('protection flag');
      entry.protectionDigestIndex = _strIndex(BinaryByteTier.semantic);
      entry.protectionDigest = _str(entry.protectionDigestIndex);
      entry.hasSecondaryDigest = _flagWord('secondary digest flag');
      if (entry.hasSecondaryDigest) {
        entry.secondaryDigestIndex = _strIndex(BinaryByteTier.semantic);
        entry.secondaryDigest = _str(entry.secondaryDigestIndex);
      }
    }
    if (BinaryPropertyFlag.extData.isSetIn(entryFlags)) root.extData = _extData();
    if (BinaryPropertyFlag.attributes.isSetIn(entryFlags)) root.attributes = _record(1, null);
    if (BinaryPropertyFlag.typeAttributes.isSetIn(entryFlags)) root.typeAttributes = _record(1, null);
    root.children = _children(1, null);
    root.end = at;
    entry.additionalTypeFlags = _u32s(BinaryByteTier.semantic);
    entry.alwaysSaveType = _u8s(BinaryByteTier.semantic) != 0;
    entry.orderNumber = _u32s(BinaryByteTier.semantic);
    entry.end = at;
    return entry;
  }

  bool _flagWord(String what) {
    final word = _u32s(BinaryByteTier.structural);
    if (word > 1) throw Tof1FormatException('$what is $word, expected 0 or 1', at - _u32);
    return word == 1;
  }

  BinaryRecord _record(int depth, BinaryRecord? definition) {
    if (depth > _maxDepth) throw Tof1FormatException('record nesting deeper than $_maxDepth', at);
    final offset = at;
    final flags = _u32s(BinaryByteTier.structural);
    _checkFlags(flags, offset);
    final flagsHigh = _u32s(BinaryByteTier.undecoded);
    if (flagsHigh != 0) throw Tof1FormatException('flags high word $flagsHigh not yet decoded', offset + _u32);
    final classIndex = _strIndex(BinaryByteTier.semantic);
    int? typeRef;
    if (BinaryPropertyFlag.typed.isSetIn(flags)) {
      typeRef = _u32s(BinaryByteTier.semantic);
    }
    final nameIndex = _strIndex(BinaryByteTier.semantic);
    final record = BinaryRecord(
      offset: offset,
      flags: flags,
      classIndex: classIndex,
      className: _str(classIndex),
      typeRef: typeRef,
      nameIndex: nameIndex,
      name: _str(nameIndex),
    );
    var def = definition;
    if (typeRef != null) {
      if (typeRef < types.length) {
        final type = types[typeRef];
        record.typeName = type.name;
        def = type.root;
      } else {
        throw Tof1FormatException('type reference $typeRef beyond the ${types.length} types read so far', offset);
      }
    }
    record.definition = def;
    final className = record.className ?? def?.resolvedClassName;
    if (className == null) {
      throw Tof1FormatException('class of ${record.name ?? '<unnamed>'} is inherited from a type not yet read', offset);
    }
    record.resolvedClassName = className;
    record.kind = SeqValueClass.from(className);
    _valuePart(record, flags, depth, def);
    if (BinaryPropertyFlag.comment.isSetIn(flags)) {
      record.commentIndex = _strIndex(BinaryByteTier.semantic);
      record.comment = _str(record.commentIndex);
    }
    _attributeWords(record, flags);
    if (BinaryPropertyFlag.extData.isSetIn(flags)) record.extData = _extData();
    if (BinaryPropertyFlag.attributes.isSetIn(flags)) record.attributes = _record(depth + 1, null);
    if (BinaryPropertyFlag.typeAttributes.isSetIn(flags)) record.typeAttributes = _record(depth + 1, null);
    record.children = _children(depth + 1, def);
    record.end = at;
    return record;
  }

  void _valuePart(BinaryRecord record, int flags, int depth, BinaryRecord? definition) {
    final hasValue = BinaryPropertyFlag.value.isSetIn(flags);
    switch (record.kind) {
      case SeqValueClass.numbers ||
          SeqValueClass.strings ||
          SeqValueClass.booleans ||
          SeqValueClass.references ||
          SeqValueClass.objects ||
          SeqValueClass.containers:
        record.lboundIndex = _strIndex(BinaryByteTier.semantic);
        record.uboundIndex = _strIndex(BinaryByteTier.semantic);
        record.lbound = _str(record.lboundIndex);
        record.ubound = _str(record.uboundIndex);
        if (!hasValue) throw Tof1FormatException('array without the value bit', record.offset);
        BinaryRecord? elementDefinition;
        if (record.kind == SeqValueClass.objects || record.kind == SeqValueClass.containers) {
          record.hasElemProto = _u8s(BinaryByteTier.structural) != 0;
          if (record.hasElemProto) {
            record.elemProto = _record(depth + 1, definition?.elemProto);
          }
          elementDefinition = record.elemProto ?? definition?.elemProto;
        }
        final count = arrayBoundCount(record.lbound, record.ubound);
        if (count > recordRegionLength - at) {
          throw Tof1FormatException('$count array elements exceed the record region', at);
        }
        final elements = List<Object?>.filled(count, null);
        final indices = record.kind == SeqValueClass.strings ? List<int>.filled(count, 0) : null;
        for (var i = 0; i < count; i++) {
          switch (record.kind) {
            case SeqValueClass.numbers:
              elements[i] = _f64s();
            case SeqValueClass.strings:
              final index = _strIndex(BinaryByteTier.semantic);
              indices![i] = index;
              elements[i] = _str(index);
            case SeqValueClass.booleans:
              elements[i] = _u8s(BinaryByteTier.semantic) != 0;
            case SeqValueClass.references:
              elements[i] = _u32s(BinaryByteTier.semantic);
            default:
              elements[i] = _record(depth + 1, elementDefinition);
          }
        }
        record.elements = elements;
        record.elementIndices = indices;
      case SeqValueClass.number:
        if (BinaryPropertyFlag.numericRepresentation.isSetIn(flags)) {
          record.representation = _u32s(BinaryByteTier.semantic);
        }
        if (hasValue) {
          final representation = BinaryNumericRepresentation.of(_representationOf(record));
          record.value = switch (representation) {
            null => _f64s(),
            BinaryNumericRepresentation.int64 => _i64s(true),
            BinaryNumericRepresentation.uint64 => _i64s(false),
          };
        }
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        if (hasValue) {
          record.valueIndex = _strIndex(BinaryByteTier.semantic);
          record.value = _str(record.valueIndex);
        }
      case SeqValueClass.boolean:
        if (hasValue) record.value = _u8s(BinaryByteTier.semantic) != 0;
      case SeqValueClass.reference:
        break;
      case SeqValueClass.enumeration:
        if (BinaryPropertyFlag.enumItems.isSetIn(flags)) {
          record.enumItemsWord = _u32s(BinaryByteTier.undecoded);
          record.enumItems = _record(depth + 1, null);
        }
        if (BinaryPropertyFlag.enumValue.isSetIn(flags)) {
          record.enumValueIndex = _strIndex(BinaryByteTier.semantic);
          record.enumValueName = _str(record.enumValueIndex);
          record.enumValue = _f64s();
        }
      case SeqValueClass.object || SeqValueClass.step || SeqValueClass.sequence || SeqValueClass.other:
        if (hasValue) {
          throw Tof1FormatException('value bit on container class ${record.resolvedClassName}', record.offset);
        }
    }
  }

  int? _representationOf(BinaryRecord record) {
    BinaryRecord? node = record;
    var guard = 0;
    while (node != null && guard++ < _maxDepth) {
      if (node.representation != null) return node.representation;
      final typeRef = node.typeRef;
      if (typeRef != null && typeRef < types.length && types[typeRef].root.representation != null) {
        return types[typeRef].root.representation;
      }
      node = node.definition;
    }
    return null;
  }

  void _attributeWords(BinaryRecord record, int flags) {
    if (BinaryPropertyFlag.numericFormat.isSetIn(flags)) {
      record.formatIndex = _strIndex(BinaryByteTier.semantic);
      record.numericFormat = _str(record.formatIndex);
    }
    if (BinaryPropertyFlag.flagsForInstances.isSetIn(flags)) record.flagsForInstances = _u32s(BinaryByteTier.semantic);
    if (BinaryPropertyFlag.instanceOverrideFlags.isSetIn(flags)) {
      record.instanceOverrideFlags = _u32s(BinaryByteTier.semantic);
    }
    if (flags & (BinaryPropertyFlag.valueFlags.bit | BinaryPropertyFlag.structureFlags.bit) != 0) {
      record.valueFlagsWord = _u32s(BinaryByteTier.semantic);
    }
  }

  List<BinaryExtData> _extData() {
    final count = _u32s(BinaryByteTier.structural);
    if (count > _maxExtData) throw Tof1FormatException('$count extdata entries', at - _u32);
    final out = <BinaryExtData>[];
    for (var i = 0; i < count; i++) {
      final controllerIndex = _strIndex(BinaryByteTier.semantic);
      final controller = ExtDataController.byName(_str(controllerIndex) ?? '');
      if (controller == null) {
        throw Tof1FormatException('extdata controller ${_str(controllerIndex)} not yet decoded', at - _u32);
      }
      switch (controller) {
        case ExtDataController.struct:
          final allow = _u8s(BinaryByteTier.semantic) != 0;
          final packing = _u32s(BinaryByteTier.semantic);
          final exclude = _u8s(BinaryByteTier.semantic) != 0;
          final type = _u32s(BinaryByteTier.semantic);
          final arrayStorage = _u32s(BinaryByteTier.semantic);
          final strBufferSize = _u32s(BinaryByteTier.semantic);
          final strStorage = _u32s(BinaryByteTier.semantic);
          out.add(
            BinaryExtData(
              controller: controller,
              controllerIndex: controllerIndex,
              allowPassing: allow,
              exclude: exclude,
              packingOption: packing,
              type: type,
              arrayStorage: arrayStorage,
              strBufferSize: strBufferSize,
              strStorage: strStorage,
            ),
          );
        case ExtDataController.cluster || ExtDataController.lvCluster || ExtDataController.dotNetStruct:
          final allow = _u8s(BinaryByteTier.semantic) != 0;
          final exclude = _u8s(BinaryByteTier.semantic) != 0;
          final memberIndex = _strIndex(BinaryByteTier.semantic);
          out.add(
            BinaryExtData(
              controller: controller,
              controllerIndex: controllerIndex,
              allowPassing: allow,
              exclude: exclude,
              memberIndex: memberIndex,
              member: _str(memberIndex),
            ),
          );
      }
    }
    return out;
  }

  List<BinaryRecord> _children(int depth, BinaryRecord? definition) {
    final count = _u32s(BinaryByteTier.structural);
    if (count > (recordRegionLength - at) ~/ _minRecordBytes) {
      throw Tof1FormatException('$count children exceed the record region', at - _u32);
    }
    if (count == 0) return const [];
    final children = <BinaryRecord>[];
    for (var i = 0; i < count; i++) {
      final childDefinition = definition == null ? null : _definitionChild(definition, _peekName());
      children.add(_record(depth, childDefinition));
    }
    return children;
  }

  /// The name of the record starting at [at], read without consuming it.
  String? _peekName() {
    var p = at;
    if (p + 4 * _u32 > recordRegionLength) return null;
    final flags = view.getUint32(p, Endian.little);
    p += 3 * _u32;
    if (BinaryPropertyFlag.typed.isSetIn(flags)) p += _u32;
    if (p + _u32 > recordRegionLength) return null;
    final nameIndex = view.getUint32(p, Endian.little);
    return nameIndex < pool.length ? pool[nameIndex] : null;
  }

  BinaryRecord? _definitionChild(BinaryRecord definition, String? name) {
    if (name == null) return null;
    BinaryRecord? node = definition;
    var guard = 0;
    while (node != null && guard++ < _maxDepth) {
      final direct = node.child(name);
      if (direct != null) return direct;
      final typeRef = node.typeRef;
      if (typeRef != null && typeRef < types.length) {
        final viaType = _definitionChild(types[typeRef].root, name);
        if (viaType != null) return viaType;
      }
      node = node.definition;
    }
    return null;
  }
}

/// Element count of a TestStand array from its `[l]…` and `[u]…` bound strings; 0 for an unbounded `[]`.
int arrayBoundCount(String? lbound, String? ubound) {
  final lower = _dims(lbound);
  final upper = _dims(ubound);
  if (lower == null || upper == null || lower.length != upper.length) return 0;
  var count = 1;
  for (var i = 0; i < lower.length; i++) {
    final extent = upper[i] - lower[i] + 1;
    if (extent <= 0) return 0;
    count *= extent;
  }
  return count;
}

List<int>? _dims(String? bounds) {
  if (bounds == null || bounds.isEmpty) return null;
  final out = <int>[];
  var i = 0;
  while (i < bounds.length) {
    if (bounds[i] != '[') return null;
    final close = bounds.indexOf(']', i);
    if (close < 0) return null;
    final digits = bounds.substring(i + 1, close);
    if (digits.isEmpty) return null;
    final value = int.tryParse(digits);
    if (value == null) return null;
    out.add(value);
    i = close + 1;
  }
  return out.isEmpty ? null : out;
}
