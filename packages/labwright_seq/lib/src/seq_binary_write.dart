part of 'seq_binary.dart';

enum _WirePrimitive {
  copy,

  poolRef,

  u32,

  f64,

  i64,

  byte,
}

enum _OpSource {
  struct,

  model,

  grammar,
}

class _WriteOp {
  _WriteOp(this.offset, this.primitive, this.source, this.intValue, [this.doubleValue = 0]);

  _WriteOp.copy(this.offset, int end)
    : primitive = _WirePrimitive.copy,
      source = _OpSource.struct,
      intValue = end,
      doubleValue = 0;

  final int offset;
  final _WirePrimitive primitive;
  final _OpSource source;

  /// The copy end offset, a pool index, a u32 word, an i64 value, or a byte.
  int intValue;

  double doubleValue;

  int get length => switch (primitive) {
    _WirePrimitive.copy => intValue - offset,
    _WirePrimitive.poolRef || _WirePrimitive.u32 => _u32Bytes,
    _WirePrimitive.f64 || _WirePrimitive.i64 => _f64Bytes,
    _WirePrimitive.byte => 1,
  };
}

class _DecodeSink {
  const _DecodeSink();

  static const _DecodeSink none = _DecodeSink();

  void claim(int start, int end, int tier) {}

  void demote(int start, int end) {}

  int mark() => 0;

  void rollback(int m) {}

  void rollbackTailFrom(int m, int offsetBoundary) {}

  void copy(int from, int to) {}

  void poolRef(int at, int index) {}

  void u32(int at, int value, _OpSource source) {}

  void byte(int at, int value, _OpSource source) {}

  void f64(int at, double value) {}

  void i64(int at, int value) {}

  void blob(int start, int end) {}
}

class _RecordingDecodeSink extends _DecodeSink {
  final List<_WriteOp> ops = [];

  final List<(int, int, int)> claims = [];

  final List<(int, int)> demotions = [];

  @override
  void claim(int start, int end, int tier) => claims.add((start, end, tier));

  @override
  void demote(int start, int end) => demotions.add((start, end));

  @override
  int mark() => ops.length;

  @override
  void rollback(int m) {
    if (ops.length > m) ops.length = m;
  }

  @override
  void rollbackTailFrom(int m, int offsetBoundary) {
    var w = m;
    for (var r = m; r < ops.length; r++) {
      if (ops[r].offset < offsetBoundary) ops[w++] = ops[r];
    }
    ops.length = w;
  }

  @override
  void copy(int from, int to) {
    if (to > from) ops.add(_WriteOp.copy(from, to));
  }

  @override
  void poolRef(int at, int index) => ops.add(_WriteOp(at, _WirePrimitive.poolRef, _OpSource.model, index));

  @override
  void u32(int at, int value, _OpSource source) => ops.add(_WriteOp(at, _WirePrimitive.u32, source, value));

  @override
  void byte(int at, int value, _OpSource source) => ops.add(_WriteOp(at, _WirePrimitive.byte, source, value));

  @override
  void f64(int at, double value) => ops.add(_WriteOp(at, _WirePrimitive.f64, _OpSource.model, 0, value));

  @override
  void i64(int at, int value) => ops.add(_WriteOp(at, _WirePrimitive.i64, _OpSource.model, value));

  final blobSpans = <(int, int)>[];

  @override
  void blob(int start, int end) => blobSpans.add((start, end));
}

class BinarySeqWriteModel {
  BinarySeqWriteModel._({
    required this.header,
    required this.headerHasSizeWord,
    required this.recordRegion,
    required this.pool,
    required this.poolEndsWithoutNul,
    required List<_WriteOp> plan,
  }) : _plan = plan;

  final Uint8List header;

  final bool headerHasSizeWord;

  final Uint8List recordRegion;

  final List<String> pool;

  final bool poolEndsWithoutNul;

  final List<_WriteOp> _plan;

  int get recordRegionLength => recordRegion.length;

  int get planOpCount => _plan.length;

  int get _poolByteLength {
    var total = 0;
    for (final entry in pool) {
      total += entry.length + 1;
    }
    if (poolEndsWithoutNul && pool.isNotEmpty) total -= 1;
    return total;
  }

  (int, int) poolEntryRange(int index) {
    var at = recordRegion.length;
    for (var i = 0; i < index; i++) {
      at += pool[i].length + 1;
    }
    return (at, at + pool[index].length);
  }

  int replacePoolEntry(String from, String to) {
    var replaced = 0;
    for (var i = 0; i < pool.length; i++) {
      if (pool[i] == from) {
        pool[i] = to;
        replaced++;
      }
    }
    return replaced;
  }

  int replaceF64(double from, double to) {
    var replaced = 0;
    for (final op in _plan) {
      if (op.primitive == _WirePrimitive.f64 && op.doubleValue == from) {
        op.doubleValue = to;
        replaced++;
      }
    }
    return replaced;
  }

  List<int> f64Sites(double value) => [
    for (final op in _plan)
      if (op.primitive == _WirePrimitive.f64 && op.doubleValue == value) op.offset,
  ];

  List<double> get f64Values => [
    for (final op in _plan)
      if (op.primitive == _WirePrimitive.f64) op.doubleValue,
  ];

  Uint8List writeBody() {
    final out = Uint8List(recordRegion.length + _poolByteLength);
    final view = ByteData.sublistView(out);
    for (final op in _plan) {
      switch (op.primitive) {
        case _WirePrimitive.copy:
          out.setRange(op.offset, op.intValue, recordRegion, op.offset);
        case _WirePrimitive.poolRef || _WirePrimitive.u32:
          view.setUint32(op.offset, op.intValue, Endian.little);
        case _WirePrimitive.f64:
          view.setFloat64(op.offset, op.doubleValue, Endian.little);
        case _WirePrimitive.i64:
          view.setInt64(op.offset, op.intValue, Endian.little);
        case _WirePrimitive.byte:
          out[op.offset] = op.intValue;
      }
    }
    var at = recordRegion.length;
    for (var i = 0; i < pool.length; i++) {
      final entry = pool[i];
      for (var c = 0; c < entry.length; c++) {
        final unit = entry.codeUnitAt(c);
        if (unit > 0xff) {
          throw ArgumentError('pool entry $i is not byte-valued: $entry');
        }
        out[at++] = unit;
      }
      if (at < out.length) out[at++] = 0;
    }
    return out;
  }

  Uint8List writeFile() {
    final body = writeBody();
    final deflated = ZLibCodec().encode(body);
    final compressed = deflated is Uint8List ? deflated : Uint8List.fromList(deflated);
    final out = Uint8List(header.length + compressed.length);
    out.setRange(0, header.length, header);
    if (headerHasSizeWord) {
      ByteData.sublistView(out).setUint32(header.length - _u32Bytes, body.length, Endian.little);
    }
    out.setRange(header.length, out.length, compressed);
    return out;
  }

  BinaryWriteScoreboard get scoreboard =>
      _planScoreboard(_plan, recordRegionBytes: recordRegion.length, poolBytes: _poolByteLength);
}

void _leafPropertyRecordOps(_DecodeSink ops, ByteData view, BinaryPropertyRecord record) {
  final o = record.offset;
  ops.byte(o, record.lead, _OpSource.model);
  ops.byte(o + 1, record.flagsByte, _OpSource.model);
  ops.u32(o + _PropRecordField.zeroA.offset, 0, _OpSource.grammar);
  final kind = record.kind;
  ops.u32(o + _PropRecordField.kind.offset, kind, _OpSource.model);
  ops.u32(o + _PropRecordField.zeroB.offset, 0, _OpSource.grammar);
  ops.poolRef(
    o + _PropRecordField.typeNameIndex.offset,
    view.getUint32(o + _PropRecordField.typeNameIndex.offset, Endian.little),
  );
  ops.poolRef(
    o + _PropRecordField.nameIndex.offset,
    view.getUint32(o + _PropRecordField.nameIndex.offset, Endian.little),
  );
  var consumed = _PropRecordField.value.offset;
  final rem = record.length - consumed;
  if (kind >= _propScalarKind) {
    final valueAt = o + consumed;
    switch (record.typeName) {
      case 'Str' || 'Path' || 'Expr':
        if (rem == _u32Bytes || rem == _u32Bytes + _propTerminatorWidth) {
          final word = view.getUint32(valueAt, Endian.little);
          if (record.value != null) {
            ops.poolRef(valueAt, word);
          } else {
            ops.u32(valueAt, word, _OpSource.struct);
          }
          consumed += _u32Bytes;
        }
      case 'Bool':
        if (rem == 1 || rem == 1 + _propTerminatorWidth) {
          ops.byte(valueAt, view.getUint8(valueAt), _OpSource.model);
          consumed += 1;
        }
      case 'Num':
        if (rem == _f64Bytes || rem == _f64Bytes + _propTerminatorWidth) {
          ops.f64(valueAt, view.getFloat64(valueAt, Endian.little));
          consumed += _f64Bytes;
        }
    }
  }
  if (record.length == consumed + _propTerminatorWidth) {
    ops.byte(o + consumed, 0, _OpSource.grammar);
    ops.byte(o + consumed + 1, 0, _OpSource.grammar);
  }
}

(int, Uint8List)? _locateAndInflateBody(Uint8List bytes) {
  if (detectSeqFormat(bytes) != SeqFormat.binary) return null;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] != _zlibCmf) continue;
    if (!ZlibFlag.isKnown(bytes[i + 1])) continue;
    try {
      final out = _inflateCapped(Uint8List.sublistView(bytes, i));
      if (out != null && out.length > _minInflatedBytes) return (i, out);
    } catch (_) {}
  }
  return null;
}

BinarySeqWriteModel? parseBinarySeqWriteModel(Uint8List seqBytes) {
  final located = _locateAndInflateBody(seqBytes);
  if (located == null) return null;
  final (streamAt, body) = located;
  final header = seqBytes.sublist(0, streamAt);
  final hasSizeWord =
      streamAt >= _u32Bytes &&
      ByteData.sublistView(seqBytes).getUint32(streamAt - _u32Bytes, Endian.little) == body.length;

  final decoded = _decodeBody(body);
  if (decoded == null) {
    return BinarySeqWriteModel._(
      header: header,
      headerHasSizeWord: hasSizeWord,
      recordRegion: body,
      pool: [],
      poolEndsWithoutNul: false,
      plan: [_WriteOp.copy(0, body.length)],
    );
  }
  return BinarySeqWriteModel._(
    header: header,
    headerHasSizeWord: hasSizeWord,
    recordRegion: Uint8List.sublistView(body, 0, decoded.boundary),
    pool: decoded.pool,
    poolEndsWithoutNul: body.isNotEmpty && body[body.length - 1] != 0,
    plan: _buildWritePlan(decoded.stream.ops, decoded.boundary),
  );
}

List<_WriteOp> _buildWritePlan(List<_WriteOp> ops, int boundary) {
  final indexed = List<int>.generate(ops.length, (i) => i);
  indexed.sort((a, b) {
    final byOffset = ops[a].offset.compareTo(ops[b].offset);
    return byOffset != 0 ? byOffset : a.compareTo(b);
  });
  final plan = <_WriteOp>[];
  var cursor = 0;
  for (final i in indexed) {
    final op = ops[i];
    if (op.offset < cursor) continue;
    final end = op.offset + op.length;
    if (end > boundary) continue;
    if (op.offset > cursor) plan.add(_WriteOp.copy(cursor, op.offset));
    plan.add(op);
    cursor = end;
  }
  if (cursor < boundary) plan.add(_WriteOp.copy(cursor, boundary));
  return plan;
}
