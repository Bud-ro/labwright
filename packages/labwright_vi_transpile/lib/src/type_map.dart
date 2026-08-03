/// The **type map**: what each entry of a VI's consolidated type pool
/// ([ViType]) becomes in Dart.
///
/// Every pool entry lands in exactly one of three buckets ([LvMapStatus]), so
/// a sweep over a corpus can prove that nothing is silently unaccounted for:
///
/// - [LvMapStatus.mapped] — a decided Dart representation ([LvTypeMapping.dartType]).
/// - [LvMapStatus.internal] — a descriptor that is not a dataflow value at all
///   (a connector-pane signature, a data-space storage block, an alignment
///   marker). Deliberately has no Dart type; see [kInternalTypeCodes].
/// - [LvMapStatus.unmapped] — a real value type whose Dart representation is
///   not yet decided. The review list; see [kUnmappedTypeCodes].
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';

/// The names of the runtime types a translated VI refers to. They are declared
/// by the generated runtime, not by this package — collected here so the type
/// map and the eventual generator cannot disagree about their spelling.
abstract final class LvRuntimeType {
  /// A LabVIEW error cluster `{status: bool, code: I32|U32, source: String}`,
  /// which is also the payload thrown under [LvErrorMode.exceptions].
  static const String error = 'LvError';

  /// The **cleared** error value — no error, no warning. It is what an error
  /// wire carries once [LvErrorMode.exceptions] has removed its source from a
  /// signature: a caller that failed threw instead of returning, so control
  /// only reaches the reader with no error in hand.
  static const String clearedError = '$error.none';

  /// A LabVIEW file path — a rooted or relative component list, not a string
  /// (LabVIEW stores it as a `PTH0` record with its own separator rules).
  static const String path = 'LvPath';

  /// An opaque LabVIEW reference handle. Refnum descriptors carry a
  /// discriminator this reader does not decode (see [kRefnumSubtypeNote]), so
  /// the handle is not specialized per reference class.
  static const String refnum = 'LvRefnum';

  /// A LabVIEW variant: a self-describing value kept as its flattened bytes
  /// plus its type descriptor, since variant payloads are not decoded.
  static const String variant = 'LvVariant';

  /// A multi-dimensional array: a **flat, row-major** typed list plus a
  /// `Uint32List` of dimension lengths. See [lvArrayDartType].
  static const String arrayNd = 'LvArrayNd';

  /// The Dart type a generated enum falls back to when neither the enum
  /// descriptor nor a wrapping typedef supplies a name; the generator
  /// allocates a unique name of its own.
  static const String anonymousEnum = 'LvEnum';
}

/// The [LvRuntimeType] names `package:labwright_lv_runtime` declares — every
/// one except [LvRuntimeType.anonymousEnum], which the generator declares in
/// the file that uses it.
const Set<String> kLvRuntimeDeclaredTypes = {
  LvRuntimeType.error,
  LvRuntimeType.path,
  LvRuntimeType.refnum,
  LvRuntimeType.variant,
  LvRuntimeType.arrayNd,
};

/// Whether the Dart type source [dartType] names a runtime type, so a file
/// that spells it must import the runtime.
bool lvTypeNeedsRuntime(String? dartType) =>
    dartType != null && kLvRuntimeDeclaredTypes.any((name) => dartType.contains(name));

/// Which bucket a pool entry falls into.
enum LvMapStatus { mapped, internal, unmapped }

/// `VCTP` type codes that never carry a dataflow value, with the reason. These
/// are structural: connector-pane and polymorphic-VI signatures, the
/// data-space storage-block family, alignment markers and the pointer types
/// that flatten to nothing. A generator skips them rather than reviewing them.
const Map<int, String> kInternalTypeCodes = {
  TypeCode.function: 'connector-pane signature, not a value',
  TypeCode.polyVi: 'polymorphic-VI reference, not a value',
  TypeCode.block: 'data-space storage block',
  TypeCode.typeBlock: 'data-space storage block',
  TypeCode.voidBlock: 'data-space storage block',
  TypeCode.alignedBlock: 'data-space storage block',
  TypeCode.repeatedBlock: 'data-space storage block',
  TypeCode.alignmentMarker: 'data-space alignment marker',
  TypeCode.ptr: 'reference that flattens to zero bytes',
  TypeCode.ptrTo: 'pointer-to-type, a Call Library parameter mode',
  TypeCode.arrayDataPointer: 'array-data pointer, a Call Library parameter mode',
};

/// The **review list**: `VCTP` type codes that DO carry a value but have no
/// decided Dart representation, each with what is missing. Corpus counts are
/// in this package's README; the corpus sweep asserts that no code outside
/// this map and [kInternalTypeCodes] goes unmapped, so the list cannot grow
/// silently.
const Map<int, String> kUnmappedTypeCodes = {
  TypeCode.ext: 'x87 80-bit extended float; Dart has no wider-than-binary64 float, so any mapping loses precision',
  TypeCode.complexSgl: 'complex pair; no Dart complex type and no decided (re, im) representation',
  TypeCode.complexDbl: 'complex pair; no Dart complex type and no decided (re, im) representation',
  TypeCode.complexExt: 'complex pair of 80-bit extended floats',
  TypeCode.fixedPoint: 'fixed-point numeric; the descriptor\'s word length / integer word length are not decoded',
  TypeCode.complexFixedPoint: 'complex fixed-point numeric; the descriptor\'s scaling is not decoded',
  TypeCode.picture: 'LabVIEW picture (a draw-op list); the op stream is not decoded',
  TypeCode.tag: 'tag type; the fixed record after its sentinel is not decoded',
  TypeCode.subString: 'substring view; whether it carries an offset/length into another string is not decoded',
  TypeCode.subArray: 'sub-array view; its interior is a dim count and element index with no bounds, not decoded',
  TypeCode.measureData: 'waveform / timestamp / digital-waveform; the subkind word is decoded but its layout is not',
  TypeCode.unitSgl: 'physical-unit float; the unit exponent vector is not decoded',
  TypeCode.unitDbl: 'physical-unit float; the unit exponent vector is not decoded',
  TypeCode.unitExt: 'physical-unit extended float; the unit exponent vector is not decoded',
  TypeCode.unitComplexSgl: 'physical-unit complex float; the unit exponent vector is not decoded',
  TypeCode.unitComplexDbl: 'physical-unit complex float; the unit exponent vector is not decoded',
  TypeCode.unitComplexExt: 'physical-unit complex float; the unit exponent vector is not decoded',
  0x73: 'uncatalogued type code adjacent to refnum (0x70); its descriptor interior is not decoded',
  0x74: 'uncatalogued type code adjacent to refnum (0x70); its descriptor interior is not decoded',
};

/// What a refnum descriptor's first interior `u16` is: a discriminator taking
/// 17 distinct low-byte values across the corpus's 51615 refnums (`0x1e` and
/// `0x08` dominate). Which reference class each value selects is NOT decoded,
/// so every refnum maps to one opaque [LvRuntimeType.refnum] handle rather
/// than to a per-class Dart type.
///
/// What the discriminator IS measured to select is the wire word's scalar
/// depth base (see `ViSignalType.depth`), which is why that base cannot be
/// read off the type code. Over the wires whose endpoints agree on one bare
/// refnum descriptor, the base is 1 for `0x08` (4 163 wires), `0x04` (528),
/// `0x22` (302), `0x02` (114), `0x05` (84), `0x09` (12) and `0x10` (10), and 3
/// for `0x1e` (4 756) and `0x17` (1 841). The classes that ride the
/// wire-word-only `0x71` code carry an inner data type, and their base moves
/// with it — `0x12` sits at 4 for 423 wires and 5 for 267, `0x19` at 4 for 30
/// and 5 for 170, `0x20` at 5 for 315, `0x11` at 5 for 44.
const String kRefnumSubtypeNote = 'refnum reference class is not decoded; all refnums share one opaque handle';

/// The type codes that map to a Dart representation whose shape comes from the
/// descriptor's own content rather than from the code alone — the structural
/// half of [mapLvType]'s switch. Together with [LvNumericKind], the two
/// catalogues above and this set partition the code space, which is what
/// [lvTypeCodeIsAccountedFor] checks.
const Set<int> kStructuralTypeCodes = {
  TypeCode.voidType,
  TypeCode.boolean,
  TypeCode.booleanU16,
  TypeCode.string,
  TypeCode.cString,
  TypeCode.pascalString,
  TypeCode.path,
  TypeCode.variant,
  TypeCode.refnum,
  TypeCode.enumU8,
  TypeCode.enumU16,
  TypeCode.enumU32,
  TypeCode.array,
  TypeCode.cluster,
  TypeCode.typeDef,
};

/// Whether the type model accounts for the raw type-enumerator [code] at all —
/// as a mapped type, as a non-value descriptor ([kInternalTypeCodes]) or on the
/// review list ([kUnmappedTypeCodes]). False means a code nothing has looked at
/// yet; the corpus sweep asserts the corpus contains none.
bool lvTypeCodeIsAccountedFor(int code) =>
    LvNumericKind.ofCode(code) != null ||
    kStructuralTypeCodes.contains(code) ||
    kInternalTypeCodes.containsKey(code) ||
    kUnmappedTypeCodes.containsKey(code);

/// One pool entry's Dart representation.
class LvTypeMapping {
  /// A type with a decided Dart representation [dartType].
  const LvTypeMapping.mapped(this.dartType, {this.numeric, this.note, this.needsDeclaration = false})
    : status = LvMapStatus.mapped,
      unmappedCode = null;

  /// A type whose Dart spelling is a **nominal name no library declares yet**
  /// — a named cluster's or enum's class ([lvClassName]), or the anonymous-enum
  /// placeholder. Mapped, so the type model still names it; [needsDeclaration]
  /// so an emitter refuses rather than referring to a class it never writes.
  const LvTypeMapping.nominal(this.dartType, {this.note})
    : status = LvMapStatus.mapped,
      numeric = null,
      unmappedCode = null,
      needsDeclaration = true;

  /// A descriptor that is not a dataflow value ([kInternalTypeCodes]).
  const LvTypeMapping.internal(this.note)
    : status = LvMapStatus.internal,
      dartType = null,
      numeric = null,
      unmappedCode = null,
      needsDeclaration = false;

  /// A value type awaiting a representation decision ([kUnmappedTypeCodes]).
  const LvTypeMapping.unmapped(this.note, {this.unmappedCode})
    : status = LvMapStatus.unmapped,
      dartType = null,
      numeric = null,
      needsDeclaration = false;

  final LvMapStatus status;

  /// The Dart type source (`int`, `Uint8List`, `ErrorOut`, `(int, String)`), or
  /// null unless [status] is [LvMapStatus.mapped].
  final String? dartType;

  /// The numeric width model when this entry is a scalar number, else null.
  final LvNumericKind? numeric;

  /// Why the entry is internal/unmapped, or a caveat on a mapped entry.
  final String? note;

  /// Whether [dartType] names — or contains, through an array or record
  /// wrapping — a class this package does not declare. No declaration
  /// generator exists yet (TODO), so an emitter must refuse a value of such a
  /// type rather than emit source that refers to an undefined name.
  final bool needsDeclaration;

  /// For an unmapped entry, the [kUnmappedTypeCodes] code that caused it —
  /// propagated out of an array element, cluster member or typedef base, so a
  /// sweep can attribute every unmapped type to a documented root cause. Null
  /// when the cause is structural instead (a descriptor that did not frame).
  final int? unmappedCode;

  bool get isMapped => status == LvMapStatus.mapped;
}

/// The Dart representation of [type], resolved against its own pool [pool].
///
/// Total: any entry that does not resolve — an array whose element index was
/// not recovered, a cluster with an unmapped member, a typedef whose base did
/// not frame — comes back [LvMapStatus.unmapped] with the reason, never a
/// guess. [depth] bounds cluster/typedef nesting.
LvTypeMapping mapLvType(ViType type, List<ViType> pool, [int depth = 0]) {
  if (depth > 16) return const LvTypeMapping.unmapped('type nesting deeper than 16 levels');
  if (kInternalTypeCodes[type.code] case final why?) return LvTypeMapping.internal(why);
  if (kUnmappedTypeCodes[type.code] case final why?) return LvTypeMapping.unmapped(why, unmappedCode: type.code);
  if (LvNumericKind.ofCode(type.code) case final kind?) {
    return LvTypeMapping.mapped(kind.dartType, numeric: kind);
  }
  switch (type.code) {
    case TypeCode.voidType:
      return const LvTypeMapping.mapped('void');
    case TypeCode.boolean:
    case TypeCode.booleanU16:
      return const LvTypeMapping.mapped('bool');
    case TypeCode.string:
    case TypeCode.cString:
    case TypeCode.pascalString:
      return const LvTypeMapping.mapped('String', note: kStringEncodingNote);
    case TypeCode.path:
      return const LvTypeMapping.mapped(LvRuntimeType.path);
    case TypeCode.variant:
      return const LvTypeMapping.mapped(LvRuntimeType.variant, note: 'variant payloads are not decoded');
    case TypeCode.refnum:
      return const LvTypeMapping.mapped(LvRuntimeType.refnum, note: kRefnumSubtypeNote);
    case TypeCode.enumU8:
    case TypeCode.enumU16:
    case TypeCode.enumU32:
      return LvTypeMapping.nominal(
        type.name == null ? LvRuntimeType.anonymousEnum : lvClassName(type.name!),
        note: type.enumItems.isEmpty ? 'enum item labels not recovered; the generated enum has no member names' : null,
      );
    case TypeCode.array:
      return _mapArray(type, pool, depth);
    case TypeCode.cluster:
      return _mapCluster(type, pool, depth);
    case TypeCode.typeDef:
      return _mapTypeDef(type, pool, depth);
    default:
      return LvTypeMapping.unmapped(
        'type code 0x${type.code.toRadixString(16)} is not catalogued',
        unmappedCode: type.code,
      );
  }
}

/// How a LabVIEW string is carried. LabVIEW's string is a length-counted
/// **byte** sequence with no encoding attached, so the carrier is a Dart
/// `String` whose code units are those bytes (Latin-1 transcoding, which
/// round-trips every byte 0..255 exactly). Reading the string's bytes back is
/// then `latin1.encode(s)`, never `utf8.encode(s)`; interpreting the bytes as
/// UTF-8 text is the caller's decision, not the translation's.
const String kStringEncodingNote = 'byte string carried as Latin-1 code units';

LvTypeMapping _mapArray(ViType type, List<ViType> pool, int depth) {
  final elementIndex = type.elementIndex;
  if (elementIndex == null || elementIndex >= pool.length) {
    return const LvTypeMapping.unmapped('array element type not recovered from the descriptor');
  }
  final element = mapLvType(pool[elementIndex], pool, depth + 1);
  if (element.status == LvMapStatus.internal) {
    return LvTypeMapping.internal('array of a non-value element: ${element.note}');
  }
  if (!element.isMapped) {
    return LvTypeMapping.unmapped('array element is unmapped: ${element.note}', unmappedCode: element.unmappedCode);
  }
  return LvTypeMapping.mapped(
    lvArrayDartType(element, type.dimCount ?? 1),
    needsDeclaration: element.needsDeclaration,
  );
}

/// The Dart type of an array of [element] with [dimCount] dimensions.
///
/// A 1-D array is the element's exact-width storage: a `dart:typed_data` list
/// for a numeric element (so the element keeps its LabVIEW width and the data
/// stays unboxed), a plain `List<T>` for everything else — Dart has no typed
/// list for `bool`, `String`, records, or the runtime handle types.
///
/// A multi-dimensional array is [LvRuntimeType.arrayNd] over that same flat
/// storage: LabVIEW arrays are rectangular, so a flat row-major buffer plus a
/// dimension vector is both the faithful shape and the fast one, where a
/// `List<Uint8List>` of rows would admit ragged shapes LabVIEW forbids and add
/// an indirection per row. The corpus holds 1-D (30329), 2-D (1173) and 3-D
/// (132) arrays and nothing deeper, and no array whose element is itself an
/// array.
String lvArrayDartType(LvTypeMapping element, int dimCount) {
  final storage = element.numeric?.typedListType ?? 'List<${element.dartType}>';
  return dimCount <= 1 ? storage : '${LvRuntimeType.arrayNd}<$storage>';
}

/// The **growth rule**. A LabVIEW array resizes as a diagram appends to it
/// (Build Array, Insert Into Array, an auto-indexing output tunnel), while the
/// typed list that gives the element its exact width is fixed-length. The rule
/// is: *grow in a builder, convert at the boundary.*
///
/// - Every array-typed wire, terminal and signature position holds the final
///   storage from [lvArrayDartType]; nothing else ever appears in a type.
/// - A node that appends grows a **growable `List`** of the element's Dart
///   type — this returns its type — and that local never escapes the node or
///   loop that owns it.
/// - The builder is converted exactly once, where the value leaves the builder
///   (the appending node's output, or the loop's auto-indexed tunnel), by
///   [lvArrayFreeze].
///
/// Appending is then amortized O(1) and the conversion is a single bulk copy,
/// where growing a typed list per append would copy the whole array each time.
/// In-place element writes (Replace Array Subset) need no builder: they write
/// through the typed list directly.
String lvArrayBuilderType(LvTypeMapping element) => 'List<${element.dartType}>';

/// The expression converting a builder ([lvArrayBuilderType]) named
/// [builder] into the array's final storage — a typed-list copy for a numeric
/// element, and the builder itself when the storage already is a `List<T>`.
String lvArrayFreeze(LvTypeMapping element, String builder) =>
    element.numeric == null ? builder : '${element.numeric!.typedListType}.fromList($builder)';

LvTypeMapping _mapCluster(ViType type, List<ViType> pool, int depth) {
  if (isLvErrorCluster(type, pool)) return const LvTypeMapping.mapped(LvRuntimeType.error);
  final members = clusterFields(type, pool);
  if (members.length != type.members.length) {
    return const LvTypeMapping.unmapped('cluster member indices did not resolve against the pool');
  }
  final mapped = <LvTypeMapping>[];
  for (final member in members) {
    final field = mapLvType(member, pool, depth + 1);
    // A cluster holding a non-value member is itself data-space layout, not a
    // wire value: the corpus's `{cluster, ptr}`, `{refnum, ptr}` and
    // `{ptr, u32}` shapes are the data space's own records, and 46370 of the
    // 99345 clusters are of that kind.
    if (field.status == LvMapStatus.internal) {
      return LvTypeMapping.internal('cluster holding a non-value member: ${field.note}');
    }
    if (!field.isMapped) {
      return LvTypeMapping.unmapped('cluster member is unmapped: ${field.note}', unmappedCode: field.unmappedCode);
    }
    mapped.add(field);
  }
  // A named cluster becomes a nominal class; its NAME is only the preferred
  // spelling, never the identity — the corpus reuses 1460 distinct names
  // across 36977 named clusters (`error out` 6388 times, `Cluster` 328), so
  // two clusters share a class only when their member types and member names
  // agree. Collision-suffixing is the generator's job.
  if (type.name case final name? when lvClassName(name).isNotEmpty) return LvTypeMapping.nominal(lvClassName(name));
  return LvTypeMapping.mapped(
    lvRecordType(members, mapped),
    needsDeclaration: mapped.any((field) => field.needsDeclaration),
  );
}

/// The Dart **record** type an anonymous cluster becomes: named fields when
/// every member carries a distinct, sanitizable name, else positional.
///
/// 62368 of the corpus's 99345 clusters carry no name of their own. A record
/// is the right carrier for them: its identity is structural, exactly like an
/// unnamed cluster's, and it costs no generated declaration — where minting a
/// class per anonymous cluster would emit tens of thousands of one-use names
/// that nothing can refer to.
String lvRecordType(List<ViType> members, List<LvTypeMapping> mapped) {
  final names = [for (final member in members) lvFieldName(member.name ?? '')];
  final named = names.every((n) => n.isNotEmpty) && names.toSet().length == names.length;
  if (!named) return '(${[for (final field in mapped) field.dartType!].join(', ')})';
  return '({${[for (var i = 0; i < mapped.length; i++) '${mapped[i].dartType} ${names[i]}'].join(', ')}})';
}

LvTypeMapping _mapTypeDef(ViType type, List<ViType> pool, int depth) {
  final base = type.typedefBase;
  if (base == null) return const LvTypeMapping.unmapped('typedef base descriptor did not frame');
  final mapped = mapLvType(base, pool, depth + 1);
  if (mapped.status == LvMapStatus.internal) return LvTypeMapping.internal('typedef over a non-value: ${mapped.note}');
  if (!mapped.isMapped) {
    return LvTypeMapping.unmapped('typedef base is unmapped: ${mapped.note}', unmappedCode: mapped.unmappedCode);
  }
  // A typedef is nominal only where the base needs a declaration anyway — a
  // cluster or an enum. A typedef of a scalar, string or array is transparent:
  // it is a named LabVIEW control over an ordinary value, and wrapping it in a
  // Dart class would buy nothing and cost a conversion at every use.
  final nominal = base.kind == ViDataType.cluster || base.enumItems.isNotEmpty || _isEnumCode(base.code);
  final name = type.name;
  if (!nominal || name == null || lvClassName(name).isEmpty) return mapped;
  return LvTypeMapping.nominal(lvClassName(name));
}

bool _isEnumCode(int code) => code == TypeCode.enumU8 || code == TypeCode.enumU16 || code == TypeCode.enumU32;

/// Whether [type] is a LabVIEW **error cluster** — the shape whose presence
/// changes a translated VI's signature (see [LvErrorMode]).
///
/// Both the member types and the member names must agree: three members typed
/// `{boolean, I32 or U32, string}` and named `status` / `code` / `source`
/// (case-insensitively). Each half alone admits false positives; the
/// conjunction admits none in the corpus.
///
/// Corpus, over 99345 clusters: 23754 match — 23381 with an `I32` code member
/// and 373 with a `U32` one, both real LabVIEW error clusters. Types alone
/// would also take 242 `{boolean, I32, string}` clusters whose members carry
/// no recovered names; names alone would also take 6 clusters of three
/// booleans named status/code/source, and 379 clusters named status/code/
/// source whose member types differ. The 2-of-3 near misses are ordinary user
/// clusters (`control`/`shift`/`key`, `active`/`accessScope`/`code`) and stay
/// ordinary.
bool isLvErrorCluster(ViType type, List<ViType> pool) {
  if (type.members.length != 3) return false;
  final members = clusterFields(type, pool);
  if (members.length != 3) return false;
  const shape = [
    [TypeCode.boolean],
    [TypeCode.i32, TypeCode.u32],
    [TypeCode.string],
  ];
  const names = ['status', 'code', 'source'];
  for (var i = 0; i < 3; i++) {
    if (!shape[i].contains(members[i].code)) return false;
    if (members[i].name?.toLowerCase() != names[i]) return false;
  }
  return true;
}

/// [raw] sanitized to an UpperCamelCase Dart type name, or `''` when nothing
/// usable remains. Non-identifier characters split words (`error out` →
/// `ErrorOut`, `WPI_PWMDeadband.ctl` → `WpiPwmDeadbandCtl`); a leading digit
/// is prefixed with `Lv`.
String lvClassName(String raw) {
  final words = raw.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty);
  final joined = words.map((w) => w[0].toUpperCase() + (w.length == 1 ? '' : w.substring(1).toLowerCase())).join();
  if (joined.isEmpty) return '';
  return _startsWithDigit(joined) ? 'Lv$joined' : joined;
}

/// [raw] sanitized to a lowerCamelCase Dart field name, or `''` when nothing
/// usable remains. A name that would collide with a Dart reserved word, or
/// that starts with a digit, gains a trailing `$`.
String lvFieldName(String raw) {
  final name = lvClassName(raw);
  if (name.isEmpty) return '';
  final lower = name[0].toLowerCase() + name.substring(1);
  return _kReservedWords.contains(lower) || _startsWithDigit(lower) ? '$lower\$' : lower;
}

bool _startsWithDigit(String s) => s.codeUnitAt(0) >= 0x30 && s.codeUnitAt(0) <= 0x39;

/// The Dart reserved words a sanitized field name may not be.
const Set<String> _kReservedWords = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extends', //
  'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch',
  'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};
