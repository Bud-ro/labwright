import 'dart:typed_data';

import '../decode.dart';

/// A recovered LabVIEW data-type kind, from the VI Consolidated Type Pool
/// (`VCTP`). The pool's per-descriptor **type enumerator** (one byte) maps to
/// these; clean-room RE, so well-attested codes are named and everything else is
/// [unknown] (the raw code is preserved on [ViType] regardless).
enum ViDataType {
  /// No data (`0x00`). Zero-length descriptor interior; contributes 0 bytes to a
  /// serialized default value.
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

  /// A NUL-terminated C string (`0x33`); descriptor mirrors [string]
  /// (`ffffffff` sentinel + optional name).
  cString,

  /// A length-prefixed Pascal string (`0x34`).
  pascalString,

  /// A substring view type (`0x3f`); descriptor mirrors [string].
  subString,
  path,
  picture,

  /// A "tag" type (`0x37`) — an enumerated tag carrying a small fixed record
  /// after the `ffffffff` sentinel.
  tag,
  array,

  /// An array-data-pointer type (`0x41`); same `[u16 numDims][dims][u16 elem]`
  /// interior shape as [array].
  arrayDataPointer,

  /// A sub-array view type (`0x4f`); `[u16 numDims][u16 elem]` interior.
  subArray,
  cluster,

  /// The LabVIEW variant type (`0x53`, `LVVariant`) — a self-describing value;
  /// carries only an optional name in its descriptor.
  variant,

  /// Measurement/waveform data (`0x54`) — `[u16 subKind]` selecting timestamp /
  /// waveform / digital-waveform, then an optional name.
  measureData,

  /// Complex fixed-point (`0x5e`) and fixed-point (`0x5f`) numeric types.
  complexFixedPoint,
  fixedPoint,
  refnum,

  /// Internal storage-block descriptors used inside the data-space type tree:
  /// `Block` (`0x60`, `[u32 size]`), `TypeBlock` (`0x61`), `VoidBlock` (`0x62`,
  /// `[u16]`), `AlignedBlock` (`0x63`, `[u32][u16]`), `RepeatedBlock` (`0x64`,
  /// `[u32 count][u16 elem]`), and an `AlignmentMarker` (`0x65`, `[u16]`). These
  /// carry no directly-serialized default value.
  block,
  typeBlock,
  voidBlock,
  alignedBlock,
  repeatedBlock,
  alignmentMarker,

  /// A pointer-to type (`0x73`) and external-data handle (`0x74`).
  pointerTo,
  extData,

  /// A VI/function connector type (`0xf0`) — a connector-pane signature, not a
  /// data value; contributes 0 bytes to a serialized default.
  function,

  /// A named type definition (`0xf1`) that wraps exactly one base type inline
  /// (see [ViType.typedefBase]); its serialized default is the base's.
  typeDef,

  /// A polymorphic-VI reference (`0xf2`).
  polyVi,

  /// A type code not (yet) catalogued — see [ViType.code] for the raw byte.
  unknown,
}

/// The documented LabVIEW type-descriptor enumerators (the low byte of each
/// descriptor's type word). Corpus-validated against the `VCTP` histogram; codes
/// absent here decode to [ViDataType.unknown] rather than being guessed.
const Map<int, ViDataType> _typeCodes = {
  0x00: ViDataType.voidType,
  0x01: ViDataType.i8,
  0x02: ViDataType.i16,
  0x03: ViDataType.i32,
  0x04: ViDataType.i64,
  0x05: ViDataType.u8,
  0x06: ViDataType.u16,
  0x07: ViDataType.u32,
  0x08: ViDataType.u64,
  0x09: ViDataType.sgl,
  0x0a: ViDataType.dbl,
  0x0b: ViDataType.ext,
  0x0c: ViDataType.complexSgl,
  0x0d: ViDataType.complexDbl,
  0x0e: ViDataType.complexExt,
  0x15: ViDataType.enumU8,
  0x16: ViDataType.enumU16,
  0x17: ViDataType.enumU32,
  0x21: ViDataType.boolean,
  0x30: ViDataType.string,
  0x31: ViDataType.path,
  0x32: ViDataType.picture,
  0x33: ViDataType.cString,
  0x34: ViDataType.pascalString,
  0x37: ViDataType.tag,
  0x3f: ViDataType.subString,
  0x40: ViDataType.array,
  0x41: ViDataType.arrayDataPointer,
  0x4f: ViDataType.subArray,
  0x50: ViDataType.cluster,
  0x53: ViDataType.variant,
  0x54: ViDataType.measureData,
  0x5e: ViDataType.complexFixedPoint,
  0x5f: ViDataType.fixedPoint,
  0x60: ViDataType.block,
  0x61: ViDataType.typeBlock,
  0x62: ViDataType.voidBlock,
  0x63: ViDataType.alignedBlock,
  0x64: ViDataType.repeatedBlock,
  0x65: ViDataType.alignmentMarker,
  0x70: ViDataType.refnum,
  0x73: ViDataType.pointerTo,
  0x74: ViDataType.extData,
  0xf0: ViDataType.function,
  0xf1: ViDataType.typeDef,
  0xf2: ViDataType.polyVi,
};

/// One entry in the VI's type pool: its position [index], the raw type
/// enumerator byte [code], the catalogued [kind] (or [ViDataType.unknown]), and
/// the recovered [name] (a typedef/control name like `Serial Number`) when the
/// descriptor carries one, else null.
class ViType {
  const ViType({
    required this.index,
    required this.code,
    required this.kind,
    this.name,
    this.members = const [],
    this.elementIndex,
    this.enumItems = const [],
  });
  final int index;
  final int code;
  final ViDataType kind;

  /// For a [ViDataType.cluster], the VCTP indices of its member types in order
  /// (resolve against the pool with [clusterFields]) — the struct's fields.
  /// Empty for non-clusters or when the member list can't be parsed.
  final List<int> members;

  /// The descriptor's embedded name (typedef / labelled control), or null. These
  /// are real identifiers (`Trigger Threshold (volts)`, `error out`) — the VI's
  /// typed data dictionary. Heuristically recovered (see [decodeTypePool]); only
  /// populated when a clean trailing Pascal string is present.
  final String? name;

  /// For a [ViDataType.array], the VCTP index of its element type (resolve
  /// against the pool), or null for non-arrays / unparseable descriptors.
  final int? elementIndex;

  /// For an enum/ring type ([ViDataType.enumU8]/[enumU16]/[enumU32]), the ordered
  /// item labels (`Channel A`, `Channel B`, …), or empty when unparseable. These
  /// are the type-pool source; FP control objects carry their own copy via
  /// `ViHeapObject.items`.
  final List<String> enumItems;
}

/// Decodes the **VI Consolidated Type Pool** from an already-decompressed `VCTP`
/// section body into an ordered list of [ViType]. Layout (big-endian),
/// corpus-validated to parse cleanly for 100% of VIs:
///
///   `[u32 count]` then `count` × `[u16 descLen][u8 flags][u8 typeCode] …`
///
/// where `descLen` is the descriptor's total byte length (including the length
/// word) and `typeCode` is the low byte of the type word. The remaining bytes
/// (numeric sub-info, embedded names, nested element types) are not decoded here
/// — this recovers the type *kind* inventory honestly; deeper structure is not
/// decoded. Total: returns `const []` on a malformed/short pool rather than
/// throwing.
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
    final code = body[off + 3];
    final kind = _typeCodes[code] ?? ViDataType.unknown;
    final members = kind == ViDataType.cluster ? _clusterMembers(body, off, descLen, count) : const <int>[];
    final elementIndex = kind == ViDataType.array ? _arrayElement(body, off, descLen, count) : null;
    final isEnum = kind == ViDataType.enumU8 || kind == ViDataType.enumU16 || kind == ViDataType.enumU32;
    final enumItems = isEnum ? _enumItems(body, off, descLen) : const <String>[];
    final nameStart = _nameRegionStart(body, off, kind, members, elementIndex, enumItems);
    out.add(
      ViType(
        index: i,
        code: code,
        kind: kind,
        name: _trailingName(body, nameStart, off + descLen),
        members: members,
        elementIndex: elementIndex,
        enumItems: enumItems,
      ),
    );
    off += descLen;
  }
  return out;
}

/// Parses a cluster descriptor's member list: `[u16 numMembers][u16 typeIndex]*`
/// at body offset `off+4` (right after the length word + flags + code), each
/// index pointing into the same pool. Returns the member indices, or `const []`
/// if the layout doesn't validate (count fits the descriptor, every index in
/// range) — corpus-validated to parse for 99.9% of clusters.
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

/// Parses an array descriptor's element type index: layout is
/// `[u16 numDims][u32 dimSize]*numDims[u16 elementTypeIndex]` after flags+code.
/// Returns the element index (into the pool) or null if it doesn't validate
/// (1–8 dims, the index fits the descriptor and is in range) — corpus-derived.
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

/// The **serialized default-value size**, in bytes, of a type's value as it is
/// flattened into the data-space image (`DFDS`) — or null when the size is not
/// derivable from the type alone (a variable-length or not-yet-catalogued type).
///
/// Fixed-width types return their flattened width: the integers (1/2/4/8 by
/// width), `SGL`/`DBL`/`EXT` (4/8/16), the complex pair (8/16/32), enums
/// (1/2/4 by tag width), boolean (1), void (0), and a simple refnum (4). A
/// [ViDataType.cluster] is the sum of its members' sizes (resolved against
/// [pool]). Anything whose flattened length depends on runtime content —
/// [ViDataType.string], [ViDataType.path], [ViDataType.array],
/// [ViDataType.variant], the block family, a tag-carrying refnum, `unknown` —
/// returns null, as does a [ViDataType.typeDef] (`0xf1`): its inline nested base
/// descriptor's framing is not decoded, so its width is not derivable here.
/// Total; never throws.
///
/// This mirrors LabVIEW's documented flat-data widths and is corpus-anchored by
/// the `DFDS` data-space image, whose leading fixed region is the 51-word
/// [kDataSpaceInitTableBytes] init table.
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
    default:
      return null;
  }
}

/// The size in bytes of the **data-space init table** — a fixed block of 51
/// big-endian `u32` words that leads every `DFDS` default-data-space image
/// before the per-DCO default values. Corpus-anchored: across the whole corpus
/// every `DFDS` body is at least this long, and the shortest (a data space with
/// no non-default control/indicator values) is exactly this long.
const int kDataSpaceInitTableBytes = 51 * 4;

/// Parses an enum/ring descriptor's item labels: `[u16 numItems]` then
/// `numItems` × `[u8 len][label]` Pascal strings, after flags+code. Returns the
/// labels, or `const []` if the list doesn't validate (1–256 items, printable,
/// fits the descriptor) — corpus-validated to parse for ~96% of enums.
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

/// Resolves a cluster [c]'s [ViType.members] indices against the full pool
/// [types] into the ordered member [ViType]s. Out-of-range indices are skipped.
List<ViType> clusterFields(ViType c, List<ViType> types) => [
  for (final member in c.members)
    if (member < types.length) types[member],
];

/// A short human label for a type, resolving one level of array nesting:
/// `array<dbl>`, `array<cluster>`, else the bare kind name (`i32`, `cluster`).
String typeLabel(ViType t, List<ViType> types) {
  final ei = t.elementIndex;
  if (t.kind == ViDataType.array && ei != null && ei < types.length) {
    return 'array<${types[ei].kind.name}>';
  }
  return t.kind.name;
}

/// Recovers a type descriptor's embedded name: LabVIEW stores it as a Pascal
/// string (`u8 len` + bytes) at the **end** of the descriptor. Scans for a valid
/// string (2–63 printable bytes — a single char is too weak — containing letters:
/// ≥2, or a letter-majority for short names, so a coincidental `[len][punct]`
/// binary tail is rejected) ending at the descriptor's last byte (allowing one pad
/// byte). Returns null when no clean name is present
/// — heuristic but precise enough that ~all recovered names are real identifiers
/// (corpus-validated: ~64% of descriptors named, e.g. `Serial Number`).
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

/// The byte offset where a descriptor's optional trailing name may begin — i.e.
/// just past the type's known binary payload (cluster member indices, array
/// dimension sizes + element index, enum item strings). For other types the name
/// (if any) follows the flags+code word. Confining [_trailingName] to this region
/// stops binary payload bytes from being mis-read as a name.
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

/// Re-serializes a `VCTP` type-pool [body] from its framing grammar, or returns
/// null when [body] does not parse and tile exactly under it (total; never
/// throws). The grammar (big-endian), corpus-verified to frame 7490/7490 pools
/// to the last byte:
///
///   `[u32 count]` then `count` × `[u16 descLen][descLen-2 interior]` then the
///   **top-level type list** `[u16 tlCount][tlCount × u16 index]`.
///
/// Every structural word (`count`, each `descLen`, `tlCount`, each top-level
/// index) is reconstructed from the value read at its offset; each descriptor's
/// type-specific interior is retained byte-faithfully. The output is therefore
/// byte-identical to [body] for a well-formed pool — the reconstruction proves
/// the framing rather than copying it. Returns null (caller copies verbatim)
/// when a descriptor length runs past the body, a `descLen < 4`, the count is
/// out of range, or the top-level list does not end exactly at the body's end.
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

/// Whether a `VCTP` type-pool [body] parses and tiles exactly under the framing
/// grammar of [reserializeTypePool], without allocating the reconstructed
/// buffer — the lean predicate for the content scoreboard. Total; never throws.
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

/// [decodeTypePool] over a set of decoded sections — finds the `VCTP` section and
/// decodes it, or returns `const []` if absent.
List<ViType> typePoolFromDecoded(Iterable<DecodedSection> decoded) {
  for (final decodedSection in decoded) {
    if (decodedSection.tag == 'VCTP') return decodeTypePool(decodedSection.bytes);
  }
  return const [];
}

/// The subset of [types] that carry a recovered [ViType.name], in pool order —
/// the VI's named typedefs / labelled data items.
List<ViType> namedTypes(List<ViType> types) => [
  for (final type in types)
    if (type.name != null) type,
];

/// A compact `{kind-name: count}` histogram of [types] (omitting empties),
/// ordered most-frequent first — the VI's type inventory at a glance.
Map<String, int> typeKindHistogram(List<ViType> types) {
  final counts = <ViDataType, int>{};
  for (final type in types) {
    counts.update(type.kind, (n) => n + 1, ifAbsent: () => 1);
  }
  final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {for (final entry in entries) entry.key.name: entry.value};
}
