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

  void rollback(int marker) {}

  void rollbackTailFrom(int marker, int offsetBoundary) {}

  void copy(int from, int end) {}

  void poolRef(int offset, int index) {}

  void u32(int offset, int value, _OpSource source) {}

  void byte(int offset, int value, _OpSource source) {}

  void f64(int offset, double value) {}

  void i64(int offset, int value) {}

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
  void rollback(int marker) {
    if (ops.length > marker) ops.length = marker;
  }

  @override
  void rollbackTailFrom(int marker, int offsetBoundary) {
    var kept = marker;
    for (var readIndex = marker; readIndex < ops.length; readIndex++) {
      if (ops[readIndex].offset < offsetBoundary) ops[kept++] = ops[readIndex];
    }
    ops.length = kept;
  }

  @override
  void copy(int from, int end) {
    if (end > from) ops.add(_WriteOp.copy(from, end));
  }

  @override
  void poolRef(int offset, int index) => ops.add(_WriteOp(offset, _WirePrimitive.poolRef, _OpSource.model, index));

  @override
  void u32(int offset, int value, _OpSource source) => ops.add(_WriteOp(offset, _WirePrimitive.u32, source, value));

  @override
  void byte(int offset, int value, _OpSource source) => ops.add(_WriteOp(offset, _WirePrimitive.byte, source, value));

  @override
  void f64(int offset, double value) => ops.add(_WriteOp(offset, _WirePrimitive.f64, _OpSource.model, 0, value));

  @override
  void i64(int offset, int value) => ops.add(_WriteOp(offset, _WirePrimitive.i64, _OpSource.model, value));

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
    var offset = recordRegion.length;
    for (var poolIndex = 0; poolIndex < index; poolIndex++) {
      offset += pool[poolIndex].length + 1;
    }
    return (offset, offset + pool[index].length);
  }

  int replacePoolEntry(String from, String replacement) {
    var replaced = 0;
    for (var poolIndex = 0; poolIndex < pool.length; poolIndex++) {
      if (pool[poolIndex] == from) {
        pool[poolIndex] = replacement;
        replaced++;
      }
    }
    return replaced;
  }

  int replaceF64(double from, double replacement) {
    var replaced = 0;
    for (final operation in _plan) {
      if (operation.primitive == _WirePrimitive.f64 && operation.doubleValue == from) {
        operation.doubleValue = replacement;
        replaced++;
      }
    }
    return replaced;
  }

  List<int> f64Sites(double value) => [
    for (final operation in _plan)
      if (operation.primitive == _WirePrimitive.f64 && operation.doubleValue == value) operation.offset,
  ];

  List<double> get f64Values => [
    for (final operation in _plan)
      if (operation.primitive == _WirePrimitive.f64) operation.doubleValue,
  ];

  Uint8List writeBody() {
    final out = Uint8List(recordRegion.length + _poolByteLength);
    final view = ByteData.sublistView(out);
    for (final operation in _plan) {
      switch (operation.primitive) {
        case _WirePrimitive.copy:
          out.setRange(operation.offset, operation.intValue, recordRegion, operation.offset);
        case _WirePrimitive.poolRef || _WirePrimitive.u32:
          view.setUint32(operation.offset, operation.intValue, Endian.little);
        case _WirePrimitive.f64:
          view.setFloat64(operation.offset, operation.doubleValue, Endian.little);
        case _WirePrimitive.i64:
          view.setInt64(operation.offset, operation.intValue, Endian.little);
        case _WirePrimitive.byte:
          out[operation.offset] = operation.intValue;
      }
    }
    var offset = recordRegion.length;
    for (var poolIndex = 0; poolIndex < pool.length; poolIndex++) {
      final entry = pool[poolIndex];
      for (var charIndex = 0; charIndex < entry.length; charIndex++) {
        final unit = entry.codeUnitAt(charIndex);
        if (unit > 0xff) {
          throw ArgumentError('pool entry $poolIndex is not byte-valued: $entry');
        }
        out[offset++] = unit;
      }
      if (offset < out.length) out[offset++] = 0;
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
  final offset = record.offset;
  ops.byte(offset, record.lead, _OpSource.model);
  ops.byte(offset + 1, record.flagsByte, _OpSource.model);
  ops.u32(offset + _PropRecordField.zeroA.offset, 0, _OpSource.grammar);
  final kind = record.kind;
  ops.u32(offset + _PropRecordField.kind.offset, kind, _OpSource.model);
  ops.u32(offset + _PropRecordField.zeroB.offset, 0, _OpSource.grammar);
  ops.poolRef(
    offset + _PropRecordField.typeNameIndex.offset,
    view.getUint32(offset + _PropRecordField.typeNameIndex.offset, Endian.little),
  );
  ops.poolRef(
    offset + _PropRecordField.nameIndex.offset,
    view.getUint32(offset + _PropRecordField.nameIndex.offset, Endian.little),
  );
  var consumed = _PropRecordField.value.offset;
  final rem = record.length - consumed;
  final leafType = record.leafType;
  final valueBytes = leafType.valueBytes;
  if (kind >= _propScalarKind && valueBytes > 0 && (rem == valueBytes || rem == valueBytes + _propTerminatorWidth)) {
    final valueAt = offset + consumed;
    switch (leafType) {
      case PropertyLeafType.string || PropertyLeafType.path || PropertyLeafType.expression:
        final word = view.getUint32(valueAt, Endian.little);
        if (record.value != null) {
          ops.poolRef(valueAt, word);
        } else {
          ops.u32(valueAt, word, _OpSource.struct);
        }
      case PropertyLeafType.boolean:
        ops.byte(valueAt, view.getUint8(valueAt), _OpSource.model);
      case PropertyLeafType.number:
        ops.f64(valueAt, view.getFloat64(valueAt, Endian.little));
      case PropertyLeafType.object || PropertyLeafType.objects:
        break;
    }
    consumed += valueBytes;
  }
  if (record.length == consumed + _propTerminatorWidth) {
    ops.byte(offset + consumed, 0, _OpSource.grammar);
    ops.byte(offset + consumed + 1, 0, _OpSource.grammar);
  }
}

(int, Uint8List)? _locateAndInflateBody(Uint8List bytes) {
  if (detectSeqFormat(bytes) != SeqFormat.binary) return null;
  for (var streamStart = 0; streamStart + 1 < bytes.length; streamStart++) {
    if (bytes[streamStart] != _zlibCmf) continue;
    if (!ZlibFlag.isKnown(bytes[streamStart + 1])) continue;
    try {
      final out = _inflateCapped(Uint8List.sublistView(bytes, streamStart));
      if (out != null && out.length > _minInflatedBytes) return (streamStart, out);
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
  final indexed = List<int>.generate(ops.length, (index) => index);
  indexed.sort((left, right) {
    final byOffset = ops[left].offset.compareTo(ops[right].offset);
    return byOffset != 0 ? byOffset : left.compareTo(right);
  });
  final plan = <_WriteOp>[];
  var cursor = 0;
  for (final opIndex in indexed) {
    final operation = ops[opIndex];
    if (operation.offset < cursor) continue;
    final end = operation.offset + operation.length;
    if (end > boundary) continue;
    if (operation.offset > cursor) plan.add(_WriteOp.copy(cursor, operation.offset));
    plan.add(operation);
    cursor = end;
  }
  if (cursor < boundary) plan.add(_WriteOp.copy(cursor, boundary));
  return plan;
}
