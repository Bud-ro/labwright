import 'dart:typed_data';

import 'type_map.dart';
import 'type_pool.dart' show TypeCode;

class DfdsContext {
  const DfdsContext({required this.vctp, required this.tm80, required this.verGe10});

  final Uint8List vctp;

  final Uint8List tm80;

  final bool verGe10;
}

class _Pool {
  _Pool(this.body, this.descOff, this.topLevel);
  final Uint8List body;
  final List<int> descOff;
  final List<int> topLevel;
}

int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

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

int? _offOf(_Pool pool, int idx) => (idx < 0 || idx >= pool.descOff.length) ? null : pool.descOff[idx];

const int _tmSkip = (1 << 3) | (1 << 10) | (1 << 11);

const int _tmSpecial = (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6);

bool _hasSave(int flags) => (flags & ((1 << 13) | (1 << 0))) != 0;

bool _specialElement(int idx, int flags, bool verGe10) {
  if ((flags & (1 << 2)) != 0) return idx == (verGe10 ? 1 : 2);
  if ((flags & (1 << 4)) != 0) return idx == 1 || idx == 2 || idx == 3;
  if ((flags & (1 << 5)) != 0) return idx == 3;
  if ((flags & (1 << 6)) != 0) return idx == 2;
  return false;
}

int? _fixedExtent(_Pool pool, int o, int depth) {
  if (depth > 200 || o < 0 || o + 4 > pool.body.length) return null;
  final b = pool.body;
  switch (b[o + 3]) {
    case TypeCode.voidType:
    case TypeCode.voidBlock:
    case TypeCode.alignmentMarker:
    case TypeCode.ptr:
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
    case TypeCode.cString:
    case TypeCode.pascalString:
    case TypeCode.arrayDataPointer:
    case TypeCode.refnum:
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
    case TypeCode.alignedBlock:
      if (o + 8 > b.length) return null;
      return _u32(b, o + 4);
    case TypeCode.repeatedBlock:
      {
        if (o + 10 > b.length) return null;
        final n = _u32(b, o + 4);
        final cf = _fixedExtent(pool, _offOf(pool, _u16(b, o + 8)) ?? -1, depth + 1);
        if (cf == null || n > 0x7fffffff) return null;
        return n * cf;
      }
    case TypeCode.cluster:
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
    case TypeCode.typeDef:
      {
        final nested = _typedefNested(pool, o);
        return nested == null ? null : _fixedExtent(pool, nested, depth + 1);
      }
    default:
      return null;
  }
}

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
    case TypeCode.path:
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
    case TypeCode.cluster:
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
    case TypeCode.repeatedBlock:
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
    case TypeCode.typeDef:
      {
        final nested = _typedefNested(pool, o);
        return nested == null ? null : _extent(pool, nested, dfds, dfdsOff, depth + 1);
      }
    default:
      return null;
  }
}

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

class DataSpaceSlot {
  const DataSpaceSlot({required this.topLevelIndex, required this.offset, required this.length});

  final int topLevelIndex;

  final int offset;

  final int length;
}

int? _walk(Uint8List dfds, DfdsContext ctx, [void Function(int tlPos, int off, int len)? onValue]) {
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
      onValue?.call(tlPos, off, e);
      off += e;
    } else if (pool.body[descOff + 3] == TypeCode.cluster && (flags & _tmSpecial) != 0) {
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

bool dataSpaceFrames(Uint8List body, DfdsContext ctx) => _walk(body, ctx) == body.length;

Uint8List? reserializeDataSpace(Uint8List body, DfdsContext ctx) {
  return _walk(body, ctx) == body.length ? body : null;
}

List<DataSpaceSlot>? dataSpaceSlots(Uint8List body, DfdsContext ctx) {
  final slots = <DataSpaceSlot>[];
  final walked = _walk(
    body,
    ctx,
    (tlPos, off, len) => slots.add(DataSpaceSlot(topLevelIndex: tlPos, offset: off, length: len)),
  );
  return walked == body.length ? slots : null;
}
