/// Framing for the `DFDS` block — the **default fill of the data space**.
///
/// `DFDS` stores the flattened default values of a VI's data-space entries, with
/// **no offset table**: each value is laid out per its `VCTP` type and its extent
/// is implied by that type's flattened width, read sequentially. Tiling `DFDS`
/// therefore requires full type-aware flattened-value parsing — reading the
/// inline lengths of variable-width values (strings, paths, arrays) as the walk
/// proceeds — driven by the `TM80` data-space type map and the `VCTP` type pool.
///
/// The walk reproduces LabVIEW's data-space default read: [decodeTypeMap] gives
/// the per-entry list mapping each entry to a `VCTP` top-level type with a role
/// flag word; the entries carrying default data (the `HasSaveData`/`IsDSAlignPadding`
/// flags, plus the "special DSTM cluster" role clusters) are visited in type-map
/// order and each consumes one flattened value. The flattening rules are
/// clean-room, cross-referenced from the pylabview project (not LabVIEW-verified)
/// and corpus-verified by exact byte tiling: a rule is adopted only where it makes
/// `DFDS` tile to the last byte, corpus-wide. Types whose flattened form is not
/// tiled here (`LVVariant`, `MeasureData`) leave their VI's `DFDS` untiled, which
/// the writer keeps copied verbatim.
///
/// Flattened extents by `VCTP` type code (big-endian throughout):
///   * fixed-width scalars — integers/units (1/2/4/8 by width), `SGL`/`DBL`/`EXT`
///     (4/8/16), the complex pair (8/16/32), enums (1/2/4), boolean (1),
///     `void`/`VoidBlock`/`AlignmentMarker` (0), a modern `Ptr` (0), a simple
///     refnum / `PtrTo` / `ArrayDataPtr` (4), `CString`/`PasString` (4);
///   * length-prefixed — `String`/`Picture`/`Tag` (`[u32 len]` + bytes),
///     `Path` (`ident[4]` + `[u32 totlen]` + `totlen`);
///   * `Block`/`AlignedBlock` — a fixed `blkSize` byte run from the descriptor;
///   * `RepeatedBlock` — `numRepeats` × the element's flattened value;
///   * `Array` — `[u32 dim]` per descriptor dimension, then the product of the
///     inline dimensions × the element's flattened value;
///   * `Cluster` — the concatenation of its members' flattened values;
///   * `TypeDef` — the flattened value of its inline base type.
library;

import 'dart:typed_data';

import 'type_map.dart';
import 'type_pool.dart' show TypeCode;

/// The `VCTP` context a `DFDS` walk needs: the (decompressed) `VCTP` and `TM80`
/// section bodies and whether the VI's LabVIEW major version is ≥ 10 (selects one
/// version-dependent "special DSTM cluster" member index). Held as raw bodies and
/// parsed lazily by [reserializeDataSpace] / [dataSpaceFrames].
class DfdsContext {
  const DfdsContext({required this.vctp, required this.tm80, required this.verGe10});

  /// The decompressed `VCTP` consolidated-type-pool body.
  final Uint8List vctp;

  /// The decompressed `TM80` data-space type-map body.
  final Uint8List tm80;

  /// Whether the VI's LabVIEW major version is ≥ 10 (affects one special-cluster
  /// member index; see [_specialElement]).
  final bool verGe10;
}

/// The parsed `VCTP` framing a `DFDS` walk needs: each flat descriptor's byte
/// offset within [body] (indexed by descriptor index) and the top-level index
/// list (top-level index → flat descriptor index). Descriptors are addressed by
/// byte offset throughout the walk, so nested `TypeDef` base types — which live
/// inline in [body] rather than in the flat list — are handled uniformly.
class _Pool {
  _Pool(this.body, this.descOff, this.topLevel);
  final Uint8List body;
  final List<int> descOff;
  final List<int> topLevel;
}

int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Parses a `VCTP` [body] into a [_Pool] (descriptor offsets + the top-level
/// index list), or null when it does not frame (the same grammar as
/// [reserializeTypePool]). Total; never throws.
_Pool? _parsePool(Uint8List body) {
  if (body.length < 6) return null;
  final count = _u32(body, 0);
  if (count <= 0 || count > 200000) return null;
  final descOff = <int>[];
  var off = 4;
  for (var i = 0; i < count; i++) {
    if (off + 4 > body.length) return null;
    final descLen = _u16(body, off);
    if (descLen < 4 || off + descLen > body.length) return null;
    descOff.add(off);
    off += descLen;
  }
  // Top-level index list: a u2p2 count then that many u2p2 indices.
  var p = off;
  int? readVar() {
    if (p + 2 > body.length) return null;
    final hi = _u16(body, p);
    if ((hi & 0x8000) == 0) {
      p += 2;
      return hi;
    }
    if (p + 4 > body.length) return null;
    final lo = _u16(body, p + 2);
    p += 4;
    return ((hi & 0x7fff) << 16) | lo;
  }

  final tlCount = readVar();
  if (tlCount == null || tlCount > 200000) return null;
  final topLevel = <int>[];
  for (var i = 0; i < tlCount; i++) {
    final v = readVar();
    if (v == null) return null;
    topLevel.add(v);
  }
  if (p != body.length) return null;
  return _Pool(body, descOff, topLevel);
}

/// The byte offset of the flat descriptor at index [idx], or null when out of
/// range.
int? _offOf(_Pool pool, int idx) => (idx < 0 || idx >= pool.descOff.length) ? null : pool.descOff[idx];

/// The `TM80` role-flag skip mask (bits 3/10/11): an entry with any of these set
/// carries no default value in `DFDS`.
const int _tmSkip = (1 << 3) | (1 << 10) | (1 << 11);

/// The `TM80` flags selecting an entry as a "special DSTM cluster" (bits 2/4/5/6).
const int _tmSpecial = (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6);

/// Whether [flags] mark an entry's default value as present (bit 13 `HasSaveData`
/// or bit 0 `IsDSAlignPadding`).
bool _hasSave(int flags) => (flags & ((1 << 13) | (1 << 0))) != 0;

/// Whether member [idx] of a special DSTM cluster with role [flags] carries a
/// flattened default value — the member-selection rule for the bit 2/4/5/6 roles
/// (clean-room from pylabview; [verGe10] selects the bit-2 member index).
bool _specialElement(int idx, int flags, bool verGe10) {
  if ((flags & (1 << 2)) != 0) return idx == (verGe10 ? 1 : 2);
  if ((flags & (1 << 4)) != 0) return idx == 1 || idx == 2 || idx == 3;
  if ((flags & (1 << 5)) != 0) return idx == 3;
  if ((flags & (1 << 6)) != 0) return idx == 2;
  return false;
}

/// The **data-independent flattened width** of the descriptor at byte offset [o],
/// or null when the width depends on the stored value (a string, path, array, or
/// a compound containing one) or the type is not tiled here. Used both as the
/// extent of fixed types and to fast-path arrays/blocks of fixed elements. Total;
/// never throws.
int? _fixedExtent(_Pool pool, int o, int depth) {
  if (depth > 200 || o < 0 || o + 4 > pool.body.length) return null;
  final b = pool.body;
  switch (b[o + 3]) {
    case TypeCode.voidType:
    case TypeCode.voidBlock:
    case TypeCode.alignmentMarker:
    case TypeCode.ptr: // Ptr (modern LV >= 8.6: no bytes)
      return 0;
    case TypeCode.i8:
    case TypeCode.u8:
    case TypeCode.enumU8:
    case TypeCode.boolean:
      return 1;
    case TypeCode.i16:
    case TypeCode.u16:
    case TypeCode.enumU16:
    case TypeCode.booleanU16:
      return 2;
    case TypeCode.i32:
    case TypeCode.u32:
    case TypeCode.sgl:
    case TypeCode.enumU32:
    case TypeCode.unitSgl:
    case TypeCode.cString: // a fixed 4-byte value
    case TypeCode.pascalString: // a fixed 4-byte value
    case TypeCode.arrayDataPointer:
    case TypeCode.refnum: // simple refnum
    case TypeCode.ptrTo:
      return 4;
    case TypeCode.i64:
    case TypeCode.u64:
    case TypeCode.dbl:
    case TypeCode.complexSgl:
    case TypeCode.unitDbl:
    case TypeCode.unitComplexSgl:
      return 8;
    case TypeCode.ext:
    case TypeCode.complexDbl:
    case TypeCode.unitExt:
    case TypeCode.unitComplexDbl:
      return 16;
    case TypeCode.complexExt:
    case TypeCode.unitComplexExt:
      return 32;
    case TypeCode.block:
    case TypeCode.alignedBlock: // reads blkSize bytes; the client index is ignored
      if (o + 8 > b.length) return null;
      return _u32(b, o + 4);
    case TypeCode.repeatedBlock: // numRepeats x fixed element
      {
        if (o + 10 > b.length) return null;
        final n = _u32(b, o + 4);
        final cf = _fixedExtent(pool, _offOf(pool, _u16(b, o + 8)) ?? -1, depth + 1);
        if (cf == null || n > 0x7fffffff) return null;
        return n * cf;
      }
    case TypeCode.cluster: // sum of member fixed widths
      {
        if (o + 6 > b.length) return null;
        final n = _u16(b, o + 4);
        if (o + 6 + n * 2 > b.length) return null;
        var total = 0;
        for (var m = 0; m < n; m++) {
          final s = _fixedExtent(pool, _offOf(pool, _u16(b, o + 6 + m * 2)) ?? -1, depth + 1);
          if (s == null) return null;
          total += s;
        }
        return total;
      }
    case TypeCode.typeDef: // fixed width of the inline base type
      {
        final nested = _typedefNested(pool, o);
        return nested == null ? null : _fixedExtent(pool, nested, depth + 1);
      }
    default:
      return null; // string/path/array/tag/picture/variant/measuredata/unknown
  }
}

/// The flattened extent of the value for the descriptor at byte offset [o],
/// starting at [dfdsOff] in [dfds], reading inline lengths for variable-width
/// types. Returns the byte length consumed, or null when the type is not tiled
/// here or a read runs out of bounds. Total; never throws.
int? _extent(_Pool pool, int o, Uint8List dfds, int dfdsOff, int depth) {
  if (depth > 400 || o < 0 || o + 4 > pool.body.length) return null;
  final fixed = _fixedExtent(pool, o, depth);
  if (fixed != null) return fixed;
  final b = pool.body;
  switch (b[o + 3]) {
    case TypeCode.string:
    case TypeCode.picture:
    case TypeCode.tag:
      if (dfdsOff + 4 > dfds.length) return null;
      return 4 + _u32(dfds, dfdsOff);
    case TypeCode.path: // PTH0/PTH1/PTH2: ident(4) + totlen(4) + totlen bytes
      if (dfdsOff + 8 > dfds.length) return null;
      return 8 + _u32(dfds, dfdsOff + 4);
    case TypeCode.array:
      {
        if (o + 6 > b.length) return null;
        final ndim = _u16(b, o + 4);
        if (ndim < 1 || ndim > 64) return null;
        final elemPos = o + 6 + ndim * 4;
        if (elemPos + 2 > b.length) return null;
        final elemOff = _offOf(pool, _u16(b, elemPos));
        if (elemOff == null) return null;
        var total = 1;
        var consumed = 0;
        for (var k = 0; k < ndim; k++) {
          if (dfdsOff + consumed + 4 > dfds.length) return null;
          total *= _u32(dfds, dfdsOff + consumed) & 0x7fffffff;
          consumed += 4;
          if (total > 0x7fffffff) return null;
        }
        final ef = _fixedExtent(pool, elemOff, depth + 1);
        if (ef != null) {
          final bodyLen = total * ef;
          if (dfdsOff + consumed + bodyLen > dfds.length) return null;
          return consumed + bodyLen;
        }
        for (var i = 0; i < total; i++) {
          final e = _extent(pool, elemOff, dfds, dfdsOff + consumed, depth + 1);
          if (e == null) return null;
          consumed += e;
        }
        return consumed;
      }
    case TypeCode.cluster: // with at least one variable-width member
      {
        if (o + 6 > b.length) return null;
        final n = _u16(b, o + 4);
        if (o + 6 + n * 2 > b.length) return null;
        var consumed = 0;
        for (var m = 0; m < n; m++) {
          final mo = _offOf(pool, _u16(b, o + 6 + m * 2));
          if (mo == null) return null;
          final e = _extent(pool, mo, dfds, dfdsOff + consumed, depth + 1);
          if (e == null) return null;
          consumed += e;
        }
        return consumed;
      }
    case TypeCode.repeatedBlock: // with a variable-width element
      {
        if (o + 10 > b.length) return null;
        final n = _u32(b, o + 4);
        final clientOff = _offOf(pool, _u16(b, o + 8));
        if (clientOff == null || n > 0x7fffffff) return null;
        var consumed = 0;
        for (var i = 0; i < n; i++) {
          final e = _extent(pool, clientOff, dfds, dfdsOff + consumed, depth + 1);
          if (e == null) return null;
          consumed += e;
        }
        return consumed;
      }
    case TypeCode.typeDef: // with a variable-width base type
      {
        final nested = _typedefNested(pool, o);
        return nested == null ? null : _extent(pool, nested, dfds, dfdsOff, depth + 1);
      }
    default:
      return null;
  }
}

/// A `TypeDef` (`0xf1`) stores its base type as a full descriptor inline, after a
/// `[u32 flag1]` and a qualified name (`[u32 count]` then `count` Pascal
/// strings). Returns the byte offset of that inline descriptor within [pool]
/// `.body` (the descriptor at [o]), or null when it does not frame.
int? _typedefNested(_Pool pool, int o) {
  final b = pool.body;
  if (o + 12 > b.length) return null;
  final nameCount = _u32(b, o + 8);
  if (nameCount > 100000) return null;
  var p = o + 12;
  for (var i = 0; i < nameCount; i++) {
    if (p >= b.length) return null;
    p += 1 + b[p];
  }
  if (p + 4 > b.length) return null;
  final nlen = _u16(b, p);
  if (nlen < 4 || p + nlen > b.length) return null;
  return p;
}

/// Walks the whole `DFDS` body [dfds] under [ctx], returning the total number of
/// bytes the type-driven walk consumes (which equals [dfds] `.length` exactly iff
/// it tiles), or null when any entry's type is not tiled here, a read runs out of
/// bounds, or the `VCTP`/`TM80` context does not frame. Total; never throws.
int? _walk(Uint8List dfds, DfdsContext ctx) {
  final pool = _parsePool(ctx.vctp);
  if (pool == null) return null;
  final tm = decodeTypeMap(ctx.tm80);
  if (tm == null || !tm.framesExactly) return null;

  var off = 0;
  for (var i = 0; i < tm.entries.length; i++) {
    final flags = tm.entries[i];
    if ((flags & _tmSkip) != 0) continue;
    final tlPos = tm.indexShift + i - 1; // top-level index is 1-based
    if (tlPos < 0 || tlPos >= pool.topLevel.length) return null;
    final descOff = _offOf(pool, pool.topLevel[tlPos]);
    if (descOff == null) return null;

    if (_hasSave(flags)) {
      final e = _extent(pool, descOff, dfds, off, 0);
      if (e == null || off + e > dfds.length) return null;
      off += e;
    } else if (pool.body[descOff + 3] == TypeCode.cluster && (flags & _tmSpecial) != 0) {
      // A "special DSTM cluster": only selected members carry a default value,
      // with the first selected member skipped when bit 9 is set.
      if (descOff + 6 > pool.body.length) return null;
      final n = _u16(pool.body, descOff + 4);
      if (descOff + 6 + n * 2 > pool.body.length) return null;
      var skipNext = (flags & (1 << 9)) != 0;
      for (var m = 0; m < n; m++) {
        if (!_specialElement(m, flags, ctx.verGe10)) continue;
        if (skipNext) {
          skipNext = false;
          continue;
        }
        final mo = _offOf(pool, _u16(pool.body, descOff + 6 + m * 2));
        if (mo == null) return null;
        final e = _extent(pool, mo, dfds, off, 0);
        if (e == null || off + e > dfds.length) return null;
        off += e;
      }
    }
  }
  return off;
}

/// Whether a `DFDS` [body] tiles exactly under the flattened-value walk driven by
/// [ctx] — the lean predicate for the content scoreboard, without allocating the
/// reconstruction. Total; never throws.
bool dataSpaceFrames(Uint8List body, DfdsContext ctx) => _walk(body, ctx) == body.length;

/// Re-serializes a `DFDS` [body] by walking its flattened-value extents under
/// [ctx], or returns null when it does not tile exactly to the last byte (the VI
/// then keeps its `DFDS` copied verbatim). Total; never throws.
///
/// Each entry's flattened value is a byte-faithful retained leaf: the walk proves
/// the framing by consuming every byte through a typed extent, and the value
/// bytes are re-emitted verbatim, so the output is byte-identical to [body]
/// whenever it tiles. The type semantics of a value are retained opaque; the walk
/// recovers its extent, which is what tiling the data space requires.
Uint8List? reserializeDataSpace(Uint8List body, DfdsContext ctx) {
  return _walk(body, ctx) == body.length ? body : null;
}
