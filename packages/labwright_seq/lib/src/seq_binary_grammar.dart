/// Record grammar of the inflated `TOF1` body.
///
/// Every multi-byte integer is little endian and the stream is not aligned: a `u8` field shifts
/// everything after it by one byte. Strings are indices into the NUL-separated pool that follows the
/// record region; the index `0xffffffff` ([binaryNullIndex]) is the null string. Array element counts
/// come from the bound strings and are capped at [maxArrayElements].
///
/// ```text
/// body
///   u32                 typeCount
///   TypeEntry[typeCount]
///   Record              data root, class SequenceFileData (Obj in TestStand 4.x), name Data
///   u32                 tailWord              TODO: purpose not yet decoded
///   u32                 0xffffffff
///   u32                 poolCount
///   cstr[poolCount]     pool, NUL-separated, unique, Windows-1252; the last NUL may be absent
///   u8[]                poolTail              TODO: bytes after the last string, purpose not yet decoded
///
/// TypeEntry
///   u32                 entryFlags            BinaryPropertyFlag bits; typeFlags (0x10) gates the typeflags word
///   u32                 entryWord             TODO: purpose not yet decoded
///   u32                 class                 pool index
///   u32                 name                  pool index
///   ValuePart           bounds/elemproto for array classes, enum items and value for Enum
///   u32?                comment               pool index, when entryFlags & comment
///   u32                 typeCategory          1 step type, 2 custom data type, 3 built-in type
///   u32                 timestamp             seconds since 1970
///   u32                 timestampHigh         ts2014 and later only; upper half of the timestamp
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
///   u32                 flagsHigh             TODO: not yet decoded; nonzero values stop the parse
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
///   Nums/Strs/Bools     u32 lbound, u32 ubound (pool indices like '[0]' '[3]'), then one f64/u32/u8 per element
///   Refs                u32 lbound, u32 ubound; the elements carry no payload
///   Objs/Containers     u32 lbound, u32 ubound, u8 hasElemProto, Record? elemproto, Record[elements]
///   Enum                flags & enumItems: u32 itemsWord (TODO: not yet decoded), Record items (an Objs array)
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

import 'dart:typed_data';

import 'seq_binary.dart';
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
  static final int knownMask = values.fold(0, (mask, flag) => mask | flag.bit);
  bool isSetIn(int flags) => flags & bit != 0;
}

/// Bits of the valueflags word the XML writer reports as `structureflags` rather than `valueflags`.
///
/// TODO: the full set of structure bits is not yet decoded; these are the bits decoded so far.
const structureFlagMask = 0x20000 | 0x80000 | 0x200000;

/// Representation word of a `Num` whose value is stored as a 64-bit integer instead of a double.
enum BinaryNumericRepresentation {
  int64(2, 'Int64'),
  uint64(3, 'UInt64');

  const BinaryNumericRepresentation(this.code, this.xmlName);
  final int code;
  final String xmlName;
  static BinaryNumericRepresentation? of(int? code) => values.where((r) => r.code == code).firstOrNull;
  static BinaryNumericRepresentation? named(String? xmlName) => values.where((r) => r.xmlName == xmlName).firstOrNull;
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
  static ExtDataController? byName(String? name) => values.where((c) => c.controllerName == name).firstOrNull;
}

final class BinaryExtData {
  BinaryExtData(
    this.controller,
    this.controllerIndex,
    this.allowPassing,
    this.exclude, {
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
  final bool allowPassing, exclude;
  final int? packingOption, type, arrayStorage, strBufferSize, strStorage;
  final int memberIndex;
  final String? member;

  /// The entry as the attributes of an XML `<extdata>` element.
  Map<String, String> toXmlAttributes() {
    final passing = controller == ExtDataController.struct || controller == ExtDataController.dotNetStruct
        ? 'allowstructpassing'
        : 'allowclusterpassing';
    return {
      'controllername': controller.controllerName,
      passing: '$allowPassing',
      if (controller == ExtDataController.struct) 'packingoption': '$packingOption',
      'exclude': '$exclude',
      ...switch (controller) {
        ExtDataController.struct => {
          'type': '$type',
          'arraystorage': '$arrayStorage',
          'strbuffersize': '$strBufferSize',
          'strstorage': '$strStorage',
        },
        ExtDataController.dotNetStruct => {'membername': member ?? ''},
        ExtDataController.cluster || ExtDataController.lvCluster => {'memberlabel': member ?? ''},
      },
    };
  }
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
  BinaryRecord._(this.pool, this.offset, this.flags, this.classIndex, this.typeRef, this.nameIndex);
  final List<String> pool;
  final int offset;
  final int flags;

  /// Pool index of the explicit class, or [binaryNullIndex] when the class is inherited.
  final int classIndex;
  final int? typeRef;
  final int nameIndex;
  int end = 0;
  int commentIndex = binaryNullIndex, formatIndex = binaryNullIndex, valueIndex = binaryNullIndex;
  int lboundIndex = binaryNullIndex, uboundIndex = binaryNullIndex, enumValueIndex = binaryNullIndex;
  bool hasElemProto = false;
  BinaryRecord? elemProto, attributes, typeAttributes, enumItems;

  /// Array elements: [BinaryRecord]s for object arrays, `double`, `String?` or `bool` for scalar arrays, null for `Refs`.
  List<Object?>? elements;

  /// Pool indices of a `Strs` array's elements.
  List<int>? elementIndices;

  /// Body offset of the stored value: a `Num`'s eight bytes, or an array's first element; -1 when none is stored.
  int valueOffset = -1;

  /// Body offset of an `Enum`'s current enumerator value; -1 when none is stored.
  int enumValueOffset = -1;
  int? representation, flagsForInstances, instanceOverrideFlags, valueFlagsWord;

  /// TODO: the word before an `Enum` typedef's items array; purpose not yet decoded.
  int? enumItemsWord;

  /// A `double`, an `int` (integer representations), a `String?` or a `bool`; null when no value is stored.
  Object? value;
  double? enumValue;
  List<BinaryExtData> extData = const [];
  List<BinaryRecord> children = const [];

  /// The class after inheritance through the type table.
  late final String resolvedClassName;
  late final SeqValueClass kind;

  /// The record this one instantiates: a typedef root, or the matching child of the parent's definition.
  BinaryRecord? definition;
  String? typeName;
  String? _at(int index) => index == binaryNullIndex ? null : pool[index];
  String? get className => _at(classIndex);
  String? get name => _at(nameIndex);
  String? get comment => _at(commentIndex);
  String? get numericFormat => _at(formatIndex);
  String? get lbound => _at(lboundIndex);
  String? get ubound => _at(uboundIndex);
  String? get enumValueName => _at(enumValueIndex);
  bool has(BinaryPropertyFlag flag) => flag.isSetIn(flags);
  bool get isArray => kind.isArray;
  bool get isEnum => kind == SeqValueClass.enumeration;
  bool get isLeaf => !isArray && !isEnum && kind.isLeaf;

  /// `valueflags` as XML reports it: the word without the [structureFlagMask] bits.
  int? get valueFlags => has(BinaryPropertyFlag.valueFlags) ? valueFlagsWord! & ~structureFlagMask : null;

  /// `structureflags` as XML reports it: the [structureFlagMask] bits of the word.
  int? get structureFlags => has(BinaryPropertyFlag.structureFlags) ? valueFlagsWord! & structureFlagMask : null;
  BinaryRecord? child(String name) => children.where((c) => c.name == name).firstOrNull;

  Iterable<BinaryRecord> get nested sync* {
    if (enumItems case final items?) yield items;
    if (elemProto case final proto?) yield proto;
    yield* (elements ?? const []).whereType<BinaryRecord>();
    if (attributes case final block?) yield block;
    if (typeAttributes case final block?) yield block;
    yield* children;
  }

  Iterable<BinaryRecord> get tree sync* {
    yield this;
    for (final record in nested) {
      yield* record.tree;
    }
  }
}

/// One `typedef` of the type table.
final class BinaryTypeEntry {
  BinaryTypeEntry._(this.offset, this.entryWord, this.root);
  final int offset;

  /// TODO: purpose not yet decoded.
  final int entryWord;
  final BinaryRecord root;
  int category = 0, timestamp = 0, additionalTypeFlags = 0, orderNumber = 0;
  int versionIndex = binaryNullIndex, lastModVersionIndex = binaryNullIndex, minProductVersionIndex = binaryNullIndex;
  int protectionDigestIndex = binaryNullIndex, secondaryDigestIndex = binaryNullIndex;
  int? typeFlags;
  bool isProtected = false, hasSecondaryDigest = false, alwaysSaveType = false;
  String get name => root.name ?? '';
  String get version => root._at(versionIndex) ?? '';
  String get lastModVersion => root._at(lastModVersionIndex) ?? '';
  String get minProductVersion => root._at(minProductVersionIndex) ?? '';

  /// TODO: an obfuscated digest carried by protected types; its derivation is not yet decoded.
  String? get protectionDigest => root._at(protectionDigestIndex);

  /// TODO: a second digest some protected types carry; its derivation is not yet decoded.
  String? get secondaryDigest => root._at(secondaryDigestIndex);

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
    'alwayssavetype': '$alwaysSaveType',
    'additionaltypeflags': '$additionalTypeFlags',
    'typelistordernum': '$orderNumber',
  };
}

/// The body fields the grammar reads but cannot yet name.
enum BinaryUndecodedField {
  /// The word after a typedef entry's flags.
  typeEntryWord,

  /// The word after a record's flags; the parse stops when it is nonzero.
  recordFlagsHigh,

  /// The word before an `Enum` typedef's items array.
  enumItemsWord,

  /// The word between the data root and the `0xffffffff` terminator.
  bodyTailWord,

  /// Bytes after the last pool string.
  poolTail,
}

typedef BinaryUndecodedSpan = ({int start, int end, BinaryUndecodedField field});

/// The decoded body: the type table, the data root and the pool.
final class Tof1Body {
  Tof1Body._(
    this.header,
    this.bytes,
    this.types,
    this.data,
    this.tailWord,
    this.pool,
    this.poolEntries,
    this.lastStringTerminated,
    this.poolTail,
  );
  final Tof1Header header;
  final Uint8List bytes;
  final List<BinaryTypeEntry> types;
  final BinaryRecord data;

  /// TODO: purpose not yet decoded.
  final int tailWord;
  final List<String> pool;

  /// Each pool string's bytes, without its NUL.
  final List<Uint8List> poolEntries;

  /// Whether the last pool string ends with a NUL; a body may end on the string itself.
  final bool lastStringTerminated;

  /// TODO: bytes after the last pool string; purpose not yet decoded.
  final Uint8List poolTail;
  Tof1Generation get generation => header.generation;

  /// Offset of the pool count word; also the length of the record region.
  int get recordRegionLength => header.recordRegionLength;

  Iterable<BinaryRecord> get records => [for (final type in types) type.root, data].expand((root) => root.tree);

  /// Every undecoded span of the body, in offset order, with the field it belongs to.
  List<BinaryUndecodedSpan> get undecodedSpans {
    final roots = {for (final type in types) type.root};
    BinaryUndecodedSpan word(int start, BinaryUndecodedField field) => (start: start, end: start + 4, field: field);
    return [
      for (final type in types) word(type.offset + 4, BinaryUndecodedField.typeEntryWord),
      for (final record in records) ...[
        if (!roots.contains(record)) word(record.offset + 4, BinaryUndecodedField.recordFlagsHigh),
        if (record.enumItems case final items?) word(items.offset - 4, BinaryUndecodedField.enumItemsWord),
      ],
      word(data.end, BinaryUndecodedField.bodyTailWord),
      if (poolTail.isNotEmpty)
        (start: bytes.length - poolTail.length, end: bytes.length, field: BinaryUndecodedField.poolTail),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Record-region bytes whose purpose is not yet decoded.
  int get undecodedRecordBytes => [
    for (final span in undecodedSpans)
      if (span.field != BinaryUndecodedField.poolTail) span.end - span.start,
  ].fold(0, (a, b) => a + b);
}

/// Decodes a `TOF1` file, inflating its body unless [body] is given; throws [FormatException] when the header or
/// the inflation fails, and [Tof1FormatException] where the body leaves the grammar.
Tof1Body decodeTof1(Uint8List bytes, {Uint8List? body}) {
  final header = Tof1Header.parse(bytes);
  if (header == null || !header.hasBodyMarker) throw const FormatException('not a TOF1 file with a PMCZ body');
  final inflated = body ?? inflateBinaryBody(bytes);
  if (inflated == null) throw const FormatException('the TOF1 body does not inflate to its declared length');
  return _Tof1BodyParser(header, inflated).parse();
}

const _u32 = 4;
const _f64 = 8;
const _minRecordBytes = 5 * _u32;
const _maxDepth = 200;
const _maxExtData = 64;

final class _Tof1BodyParser {
  _Tof1BodyParser(this.header, this.body)
    : view = ByteData.sublistView(body),
      regionEnd = header.recordRegionLength,
      generation = header.generation;
  final Tof1Header header;
  final Uint8List body;
  final ByteData view;

  final int regionEnd;
  final Tof1Generation generation;
  final List<String> pool = [];
  final List<Uint8List> poolEntries = [];
  final List<BinaryTypeEntry> types = [];
  int at = 0;

  Tof1Body parse() {
    if (regionEnd < 2 * _u32 || regionEnd + _u32 > body.length) {
      _fail('record region length $regionEnd does not fit the body', 0);
    }
    final poolCount = view.getUint32(regionEnd, Endian.little);
    var next = regionEnd + _u32;
    var terminated = true;
    while (pool.length < poolCount && next < body.length) {
      final nul = body.indexOf(0, next);
      terminated = nul >= 0;
      final entry = Uint8List.sublistView(body, next, terminated ? nul : body.length);
      poolEntries.add(entry);
      pool.add(decodeWindows1252(entry));
      next += entry.length + (terminated ? 1 : 0);
    }
    if (pool.length != poolCount) _fail('pool count $poolCount but ${pool.length} strings follow', regionEnd);
    final typeCount = _u32s();
    if (typeCount > regionEnd ~/ _minRecordBytes) _fail('type count $typeCount exceeds the record region', 0);
    for (var i = 0; i < typeCount; i++) {
      _typeEntry();
    }
    final data = _record(0, null);
    final tailWord = _u32s();
    if (_u32s() != binaryNullIndex) _fail('expected the 0xffffffff sentinel before the pool count', at - _u32);
    if (at != regionEnd) _fail('record region ends before the pool count at 0x${regionEnd.toRadixString(16)}', at);
    return Tof1Body._(
      header,
      body,
      types,
      data,
      tailWord,
      pool,
      poolEntries,
      terminated,
      Uint8List.sublistView(body, next),
    );
  }

  Never _fail(String message, int offset) => throw Tof1FormatException(message, offset);

  void _need(int bytes) {
    if (at + bytes > regionEnd) _fail('record region ends inside a field', at);
  }

  int _u32s() {
    _need(_u32);
    final value = view.getUint32(at, Endian.little);
    at += _u32;
    return value;
  }

  bool _bool() {
    _need(1);
    return view.getUint8(at++) != 0;
  }

  double _f64s() {
    _need(_f64);
    final value = view.getFloat64(at, Endian.little);
    at += _f64;
    return value;
  }

  int _i64s(BinaryNumericRepresentation representation) {
    _need(_f64);
    final value = representation == BinaryNumericRepresentation.int64
        ? view.getInt64(at, Endian.little)
        : view.getUint64(at, Endian.little);
    at += _f64;
    return value;
  }

  /// Reads a pool index, [binaryNullIndex] for the null string.
  int _str() {
    final index = _u32s();
    if (index != binaryNullIndex && index >= pool.length) {
      _fail('pool index $index beyond the ${pool.length}-string pool', at - _u32);
    }
    return index;
  }

  int _flags() {
    final flags = _u32s();
    final unknown = flags & ~BinaryPropertyFlag.knownMask;
    if (unknown != 0) _fail('flag bits 0x${unknown.toRadixString(16)} not yet decoded', at - _u32);
    return flags;
  }

  bool _flagWord(String what) {
    final word = _u32s();
    if (word > 1) _fail('$what is $word, expected 0 or 1', at - _u32);
    return word == 1;
  }

  void _typeEntry() {
    final offset = at;
    final flags = _flags();
    final entryWord = _u32s();
    final classIndex = _str();
    if (classIndex == binaryNullIndex) _fail('a typedef needs an explicit class', at - _u32);
    final root = BinaryRecord._(pool, offset + 2 * _u32, flags, classIndex, null, _str());
    root.resolvedClassName = pool[classIndex];
    root.kind = SeqValueClass.from(root.resolvedClassName);
    final type = BinaryTypeEntry._(offset, entryWord, root);
    types.add(type);
    _valuePart(root, root.isArray ? flags | BinaryPropertyFlag.value.bit : flags, 1, null);
    if (root.has(BinaryPropertyFlag.comment)) root.commentIndex = _str();
    type.category = _u32s();
    type.timestamp = _u32s();
    if (generation.hasWideTimestamp && _u32s() != 0) _fail('type timestamp high word', at - _u32);
    type.versionIndex = _str();
    type.lastModVersionIndex = _str();
    type.minProductVersionIndex = _str();
    if (root.has(BinaryPropertyFlag.typeFlags)) type.typeFlags = _u32s();
    _attributeWords(root);
    if (generation.hasProtectionBlock) {
      type.isProtected = _flagWord('protection flag');
      type.protectionDigestIndex = _str();
      type.hasSecondaryDigest = _flagWord('secondary digest flag');
      if (type.hasSecondaryDigest) type.secondaryDigestIndex = _str();
    }
    _blocks(root, 1);
    root.children = _children(1, null);
    root.end = at;
    type.additionalTypeFlags = _u32s();
    type.alwaysSaveType = _bool();
    type.orderNumber = _u32s();
  }

  BinaryRecord _record(int depth, BinaryRecord? definition) {
    if (depth > _maxDepth) _fail('record nesting deeper than $_maxDepth', at);
    final offset = at;
    final flags = _flags();
    if (_u32s() != 0) _fail('flags high word not yet decoded', offset + _u32);
    final classIndex = _str();
    final typeRef = BinaryPropertyFlag.typed.isSetIn(flags) ? _u32s() : null;
    final record = BinaryRecord._(pool, offset, flags, classIndex, typeRef, _str());
    var def = definition;
    if (typeRef != null) {
      if (typeRef >= types.length) {
        _fail('type reference $typeRef beyond the ${types.length} types read so far', offset);
      }
      record.typeName = types[typeRef].name;
      def = types[typeRef].root;
    }
    record.definition = def;
    final className = record.className ?? def?.resolvedClassName;
    if (className == null) {
      _fail('class of ${record.name ?? '<unnamed>'} is inherited from a type not yet read', offset);
    }
    record.resolvedClassName = className;
    record.kind = SeqValueClass.from(className);
    _valuePart(record, flags, depth, def);
    if (record.has(BinaryPropertyFlag.comment)) record.commentIndex = _str();
    _attributeWords(record);
    _blocks(record, depth + 1);
    record.children = _children(depth + 1, def);
    record.end = at;
    return record;
  }

  void _valuePart(BinaryRecord record, int flags, int depth, BinaryRecord? definition) {
    final hasValue = BinaryPropertyFlag.value.isSetIn(flags);
    final kind = record.kind;
    if (kind.isArray) {
      record.lboundIndex = _str();
      record.uboundIndex = _str();
      if (!hasValue) _fail('array without the value bit', record.offset);
      BinaryRecord? elementDefinition;
      if (kind == SeqValueClass.objects || kind == SeqValueClass.containers) {
        record.hasElemProto = _bool();
        if (record.hasElemProto) record.elemProto = _record(depth + 1, definition?.elemProto);
        elementDefinition = record.elemProto ?? definition?.elemProto;
      }
      final count = arrayBoundCount(record.lbound, record.ubound);
      if (count == null) {
        _fail(
          'array bounds ${record.lbound}..${record.ubound} exceed $maxArrayElements elements',
          record.offset,
        );
      }
      if (count > regionEnd - at) _fail('$count array elements exceed the record region', at);
      record.valueOffset = at;
      if (kind == SeqValueClass.strings) record.elementIndices = List.generate(count, (_) => _str());
      record.elements = switch (kind) {
        SeqValueClass.numbers => List.generate(count, (_) => _f64s()),
        SeqValueClass.strings => [for (final index in record.elementIndices!) record._at(index)],
        SeqValueClass.booleans => List.generate(count, (_) => _bool()),
        SeqValueClass.references => List.filled(count, null),
        _ => List.generate(count, (_) => _record(depth + 1, elementDefinition)),
      };
      return;
    }
    switch (kind) {
      case SeqValueClass.number:
        if (BinaryPropertyFlag.numericRepresentation.isSetIn(flags)) record.representation = _u32s();
        if (hasValue) {
          record.valueOffset = at;
          final representation = BinaryNumericRepresentation.of(_representationOf(record));
          record.value = representation == null ? _f64s() : _i64s(representation);
        }
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        if (hasValue) record.value = record._at(record.valueIndex = _str());
      case SeqValueClass.boolean:
        if (hasValue) record.value = _bool();
      case SeqValueClass.enumeration:
        if (BinaryPropertyFlag.enumItems.isSetIn(flags)) {
          record.enumItemsWord = _u32s();
          record.enumItems = _record(depth + 1, null);
        }
        if (BinaryPropertyFlag.enumValue.isSetIn(flags)) {
          record.enumValueIndex = _str();
          record.enumValueOffset = at;
          record.enumValue = _f64s();
        }
      case SeqValueClass.object || SeqValueClass.step || SeqValueClass.sequence || SeqValueClass.other:
        if (hasValue) _fail('value bit on container class ${record.resolvedClassName}', record.offset);
      default:
        break;
    }
  }

  int? _representationOf(BinaryRecord record) {
    BinaryRecord? node = record;
    for (var guard = 0; node != null && guard < _maxDepth; guard++) {
      if (node.representation case final representation?) return representation;
      final typeRef = node.typeRef;
      if (typeRef != null && typeRef < types.length) {
        if (types[typeRef].root.representation case final representation?) return representation;
      }
      node = node.definition;
    }
    return null;
  }

  void _attributeWords(BinaryRecord record) {
    if (record.has(BinaryPropertyFlag.numericFormat)) record.formatIndex = _str();
    if (record.has(BinaryPropertyFlag.flagsForInstances)) record.flagsForInstances = _u32s();
    if (record.has(BinaryPropertyFlag.instanceOverrideFlags)) record.instanceOverrideFlags = _u32s();
    if (record.has(BinaryPropertyFlag.valueFlags) || record.has(BinaryPropertyFlag.structureFlags)) {
      record.valueFlagsWord = _u32s();
    }
  }

  void _blocks(BinaryRecord record, int depth) {
    if (record.has(BinaryPropertyFlag.extData)) {
      final count = _u32s();
      if (count > _maxExtData) _fail('$count extdata entries', at - _u32);
      record.extData = List.generate(count, (_) => _extData());
    }
    if (record.has(BinaryPropertyFlag.attributes)) record.attributes = _record(depth, null);
    if (record.has(BinaryPropertyFlag.typeAttributes)) record.typeAttributes = _record(depth, null);
  }

  BinaryExtData _extData() {
    final controllerIndex = _str();
    final name = controllerIndex == binaryNullIndex ? null : pool[controllerIndex];
    final controller = ExtDataController.byName(name);
    if (controller == null) _fail('extdata controller $name not yet decoded', at - _u32);
    final allowPassing = _bool();
    if (controller != ExtDataController.struct) {
      final exclude = _bool();
      final memberIndex = _str();
      return BinaryExtData(
        controller,
        controllerIndex,
        allowPassing,
        exclude,
        memberIndex: memberIndex,
        member: memberIndex == binaryNullIndex ? null : pool[memberIndex],
      );
    }
    final packingOption = _u32s();
    return BinaryExtData(
      controller,
      controllerIndex,
      allowPassing,
      _bool(),
      packingOption: packingOption,
      type: _u32s(),
      arrayStorage: _u32s(),
      strBufferSize: _u32s(),
      strStorage: _u32s(),
    );
  }

  List<BinaryRecord> _children(int depth, BinaryRecord? definition) {
    final count = _u32s();
    if (count > (regionEnd - at) ~/ _minRecordBytes) _fail('$count children exceed the record region', at - _u32);
    if (count == 0) return const [];
    return List.generate(
      count,
      (_) => _record(depth, definition == null ? null : _definitionChild(definition, _peekName())),
    );
  }

  /// The name of the record starting at [at], read without consuming it.
  String? _peekName() {
    if (at + 4 * _u32 > regionEnd) return null;
    final flags = view.getUint32(at, Endian.little);
    final nameAt = at + (BinaryPropertyFlag.typed.isSetIn(flags) ? 4 : 3) * _u32;
    if (nameAt + _u32 > regionEnd) return null;
    final nameIndex = view.getUint32(nameAt, Endian.little);
    return nameIndex < pool.length ? pool[nameIndex] : null;
  }

  BinaryRecord? _definitionChild(BinaryRecord definition, String? name) {
    if (name == null) return null;
    BinaryRecord? node = definition;
    for (var guard = 0; node != null && guard < _maxDepth; guard++) {
      if (node.child(name) case final direct?) return direct;
      final typeRef = node.typeRef;
      if (typeRef != null && typeRef < types.length) {
        if (_definitionChild(types[typeRef].root, name) case final viaType?) return viaType;
      }
      node = node.definition;
    }
    return null;
  }
}

/// The largest element count [arrayBoundCount] reports; larger bounds cannot fit any body.
const maxArrayElements = 0x7fffffff;

/// Element count of a TestStand array from its `[l]…` and `[u]…` bound strings: 0 for an empty or
/// malformed pair (`[]` is empty), null when the count exceeds [maxArrayElements].
int? arrayBoundCount(String? lbound, String? ubound) {
  final lower = _dims(lbound);
  final upper = _dims(ubound);
  if (lower == null || upper == null || lower.length != upper.length) return 0;
  var count = 1;
  for (var i = 0; i < lower.length; i++) {
    if (upper[i] == _oversizedBound) return null;
    final extent = upper[i] - lower[i] + 1;
    if (extent <= 0) return 0;
    if (extent > maxArrayElements || count > maxArrayElements ~/ extent) return null;
    count *= extent;
  }
  return count;
}

/// Stands for a decimal bound past [maxArrayElements]; it is never a valid index.
const _oversizedBound = maxArrayElements + 1;

final _bound = RegExp(r'\[([0-9]+)\]');

List<int>? _dims(String? bounds) {
  if (bounds == null || bounds.isEmpty) return null;
  final matches = _bound.allMatches(bounds).toList();
  if (matches.isEmpty || matches.fold(0, (n, m) => n + m.end - m.start) != bounds.length) return null;
  return [
    for (final match in matches)
      if (int.tryParse(match[1]!) case final value? when value <= maxArrayElements) value else _oversizedBound,
  ];
}
