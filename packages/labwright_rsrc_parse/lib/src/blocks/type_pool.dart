import 'dart:typed_data';

import '../decode.dart';

/// A recovered LabVIEW data-type kind, from the VI Consolidated Type Pool
/// (`VCTP`). The pool's per-descriptor **type enumerator** (one byte) maps to
/// these; clean-room RE, so well-attested codes are named and everything else is
/// [unknown] (the raw code is preserved on [ViType] regardless).
enum ViDataType {
  i8, i16, i32, i64,
  u8, u16, u32, u64,
  sgl, dbl, ext,
  complexSgl, complexDbl, complexExt,
  enumU8, enumU16, enumU32,
  boolean,
  string, path, picture,
  array, cluster, refnum,

  /// A type code not (yet) catalogued — see [ViType.code] for the raw byte.
  unknown,
}

/// The documented LabVIEW type-descriptor enumerators (the low byte of each
/// descriptor's type word). Corpus-validated against the `VCTP` histogram; codes
/// absent here decode to [ViDataType.unknown] rather than being guessed.
const Map<int, ViDataType> _typeCodes = {
  0x01: ViDataType.i8, 0x02: ViDataType.i16, 0x03: ViDataType.i32, 0x04: ViDataType.i64,
  0x05: ViDataType.u8, 0x06: ViDataType.u16, 0x07: ViDataType.u32, 0x08: ViDataType.u64,
  0x09: ViDataType.sgl, 0x0a: ViDataType.dbl, 0x0b: ViDataType.ext,
  0x0c: ViDataType.complexSgl, 0x0d: ViDataType.complexDbl, 0x0e: ViDataType.complexExt,
  0x15: ViDataType.enumU8, 0x16: ViDataType.enumU16, 0x17: ViDataType.enumU32,
  0x21: ViDataType.boolean,
  0x30: ViDataType.string, 0x31: ViDataType.path, 0x32: ViDataType.picture,
  0x40: ViDataType.array, 0x50: ViDataType.cluster, 0x70: ViDataType.refnum,
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
/// — this recovers the type *kind* inventory honestly; deeper structure is
/// future work. Total: returns `const []` on a malformed/short pool rather than
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
    final members = code == 0x50 ? _clusterMembers(body, off, descLen, count) : const <int>[];
    final elementIndex = code == 0x40 ? _arrayElement(body, off, descLen, count) : null;
    final enumItems = (code == 0x15 || code == 0x16 || code == 0x17) ? _enumItems(body, off, descLen) : const <String>[];
    final nameStart = _nameRegionStart(body, off, code, members, elementIndex, enumItems);
    out.add(ViType(
      index: i,
      code: code,
      kind: _typeCodes[code] ?? ViDataType.unknown,
      name: _trailingName(body, nameStart, off + descLen),
      members: members,
      elementIndex: elementIndex,
      enumItems: enumItems,
    ));
    off += descLen;
  }
  return out;
}

/// Parses a cluster descriptor's member list: `[u16 numMembers][u16 typeIndex]*`
/// at body offset `off+4` (right after the length word + flags + code), each
/// index pointing into the same pool. Returns the member indices, or `const []`
/// if the layout doesn't validate (count fits the descriptor, every index in
/// range) — corpus-validated to parse for 99.9% of clusters.
List<int> _clusterMembers(Uint8List b, int off, int descLen, int poolCount) {
  if (off + 6 > b.length) return const [];
  final nm = (b[off + 4] << 8) | b[off + 5];
  if (nm <= 0 || nm > 512) return const [];
  if (6 + nm * 2 > descLen) return const [];
  final out = <int>[];
  for (var m = 0; m < nm; m++) {
    final p = off + 6 + m * 2;
    final idx = (b[p] << 8) | b[p + 1];
    if (idx >= poolCount) return const [];
    out.add(idx);
  }
  return out;
}

/// Parses an array descriptor's element type index: layout is
/// `[u16 numDims][u32 dimSize]*numDims[u16 elementTypeIndex]` after flags+code.
/// Returns the element index (into the pool) or null if it doesn't validate
/// (1–8 dims, the index fits the descriptor and is in range) — corpus-derived.
int? _arrayElement(Uint8List b, int off, int descLen, int poolCount) {
  if (off + 6 > b.length) return null;
  final numDims = (b[off + 4] << 8) | b[off + 5];
  if (numDims < 1 || numDims > 8) return null;
  final ep = off + 6 + numDims * 4;
  if (ep + 2 > off + descLen) return null;
  final idx = (b[ep] << 8) | b[ep + 1];
  if (idx >= poolCount) return null;
  return idx;
}

/// Parses an enum/ring descriptor's item labels: `[u16 numItems]` then
/// `numItems` × `[u8 len][label]` Pascal strings, after flags+code. Returns the
/// labels, or `const []` if the list doesn't validate (1–256 items, printable,
/// fits the descriptor) — corpus-validated to parse for ~96% of enums.
List<String> _enumItems(Uint8List b, int off, int descLen) {
  if (off + 6 > b.length) return const [];
  final numItems = (b[off + 4] << 8) | b[off + 5];
  if (numItems < 1 || numItems > 256) return const [];
  final out = <String>[];
  var p = off + 6;
  final endPos = off + descLen;
  for (var k = 0; k < numItems; k++) {
    if (p >= endPos) return const [];
    final len = b[p];
    if (len < 1 || p + 1 + len > endPos) return const [];
    for (var j = p + 1; j < p + 1 + len; j++) {
      if (b[j] < 0x20 || b[j] >= 0x7f) return const [];
    }
    out.add(String.fromCharCodes(b.sublist(p + 1, p + 1 + len)));
    p += 1 + len;
  }
  return out;
}

/// Resolves a cluster [c]'s [ViType.members] indices against the full pool
/// [types] into the ordered member [ViType]s. Out-of-range indices are skipped.
List<ViType> clusterFields(ViType c, List<ViType> types) => [
      for (final i in c.members)
        if (i >= 0 && i < types.length) types[i],
    ];

/// A short human label for a type, resolving one level of array nesting:
/// `array<dbl>`, `array<cluster>`, else the bare kind name (`i32`, `cluster`).
String typeLabel(ViType t, List<ViType> types) {
  if (t.kind == ViDataType.array && t.elementIndex != null && t.elementIndex! < types.length) {
    return 'array<${types[t.elementIndex!].kind.name}>';
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
String? _trailingName(Uint8List b, int start, int end) {
  for (final e in [end, end - 1]) {
    if (e <= start) continue;
    for (var len = 2; len <= 63; len++) {
      final lenPos = e - len - 1;
      if (lenPos < start) break;
      if (b[lenPos] != len) continue;
      var ok = true;
      var letters = 0;
      for (var i = lenPos + 1; i < e; i++) {
        final c = b[i];
        if (c < 0x20 || c >= 0x7f) {
          ok = false;
          break;
        }
        if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) letters++;
      }
      if (ok && (letters >= 2 || letters * 2 >= len)) {
        return String.fromCharCodes(b.sublist(lenPos + 1, e));
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
int _nameRegionStart(Uint8List b, int off, int code, List<int> members, int? elementIndex, List<String> enumItems) {
  if (code == 0x50 && members.isNotEmpty) {
    return off + 6 + members.length * 2;
  }
  if (code == 0x40 && elementIndex != null && off + 6 <= b.length) {
    final numDims = (b[off + 4] << 8) | b[off + 5];
    return off + 6 + numDims * 4 + 2;
  }
  if (enumItems.isNotEmpty) {
    var p = off + 6;
    for (final it in enumItems) {
      p += 1 + it.length;
    }
    return p;
  }
  return off + 4;
}

/// [decodeTypePool] over a set of decoded sections — finds the `VCTP` section and
/// decodes it, or returns `const []` if absent.
List<ViType> typePoolFromDecoded(Iterable<DecodedSection> decoded) {
  for (final d in decoded) {
    if (d.tag == 'VCTP') return decodeTypePool(d.bytes);
  }
  return const [];
}

/// The subset of [types] that carry a recovered [ViType.name], in pool order —
/// the VI's named typedefs / labelled data items.
List<ViType> namedTypes(List<ViType> types) => [
      for (final t in types)
        if (t.name != null) t,
    ];

/// A compact `{kind-name: count}` histogram of [types] (omitting empties),
/// ordered most-frequent first — the VI's type inventory at a glance.
Map<String, int> typeKindHistogram(List<ViType> types) {
  final counts = <ViDataType, int>{};
  for (final t in types) {
    counts[t.kind] = (counts[t.kind] ?? 0) + 1;
  }
  final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {for (final e in entries) e.key.name: e.value};
}
