part of 'seq_binary.dart';

// ───────────────────────── binary TOF1 writer ─────────────────────────
//
// Re-serializes a binary TOF1 file from its parsed model. The discipline:
// every span the reader decodes SEMANTICALLY is re-emitted from typed write
// ops captured by the SAME production decode passes (pool references, inline
// f64/i64/bool values, counts, type-table references), the string pool is
// re-emitted from the recovered strings, and only the spans the decoder does
// not cover are copied verbatim from the retained body. The write ops come
// from the recorded decode stream ([_decodeBody] into a [_DecodeSink])
// — never a parallel grammar — and the coverage metrics fold the SAME stream
// (seq_binary_metrics.dart), so the writer's copy-vs-serialize decision
// mirrors the coverage tier map by construction.

/// HOW a write op's bytes go on the wire — the encoding and width. The
/// WRITER dispatches on this dimension alone ([BinarySeqWriteModel.writeBody]
/// switches over it); it says nothing about where the value came from
/// (that is [_OpSource]).
enum _WirePrimitive {
  /// Verbatim copy of `[offset, intValue)` from the retained record region.
  copy,

  /// A `u32` string-pool reference: `intValue` is the pool index; the
  /// referenced CONTENT is emitted from the model pool (so mutating the pool
  /// entry flows into the written file through the pool region).
  poolRef,

  /// A little-endian `u32` word (`intValue`).
  u32,

  /// An inline little-endian IEEE-754 double (`doubleValue`).
  f64,

  /// An inline little-endian i64 (`intValue`).
  i64,

  /// A single byte (`intValue`).
  byte,
}

/// WHERE a write op's value comes from — its provenance. The SCOREBOARD
/// buckets on this dimension alone ([_planScoreboard]); it says nothing
/// about the wire encoding (that is [_WirePrimitive]).
///
/// Two primitives have a fixed source by definition: [_WirePrimitive.copy]
/// is [struct] (retained bytes the decode does not interpret is exactly what
/// a verbatim copy re-emits), and [_WirePrimitive.poolRef] is [model] (the
/// index round-trips through the mutable model pool). Inline scalar values
/// ([_WirePrimitive.f64]/[_WirePrimitive.i64]) are decoded values the typed
/// model carries, so they are [model] by definition too.
enum _OpSource {
  /// Re-emitted from its RETAINED wire value — a span the grammar accepted
  /// without decoding and the typed model does not yet carry.
  struct,

  /// Emitted from MODEL content (pool references, counts, type refs, head
  /// fields, flag/attr words the typed model surfaces, inline scalar values).
  model,

  /// A GRAMMAR-DETERMINED constant the decode VERIFIED before emitting
  /// (framing zeros, record delimiters, terminators, alignment pads, form
  /// sentinels). Re-emittable from grammar knowledge alone — no retained
  /// bytes needed.
  grammar,
}

/// One primitive write op at an absolute record-region [offset]: a wire
/// [primitive] (how the bytes are encoded, what the writer switches on) and
/// a value [source] (where the value came from, what the scoreboard folds).
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

  /// Primitive-dependent payload: the copy END offset, a pool index, a
  /// `u32` word, an i64 value, or a byte value.
  int intValue;

  /// The f64 payload ([_WirePrimitive.f64] only).
  double doubleValue;

  int get length => switch (primitive) {
    _WirePrimitive.copy => intValue - offset,
    _WirePrimitive.poolRef || _WirePrimitive.u32 => _u32Bytes,
    _WirePrimitive.f64 || _WirePrimitive.i64 => _f64Bytes,
    _WirePrimitive.byte => 1,
  };
}

/// The typed decode stream one production decode pass records — the single
/// product both the writer and the metrics consume, so they can never
/// disagree about what is decoded.
///
/// Two event kinds are recorded:
///
///  * **Write ops** ([ops]) — the re-serialization plan's raw material
///    ([_buildWritePlan]). Trial parses that fail (the grammar backtracks)
///    roll their ops back by list-truncation marks, so the surviving ops
///    belong exclusively to committed decodes. Ops may be recorded out of
///    offset order (a count scan commits its attr words after the children
///    parsed); the plan builder sorts.
///  * **Coverage tier claims** ([claims]) and blob **demotions**
///    ([demotions]) — the byte-coverage accounting's raw material, folded
///    into the per-byte tier map by [_tiersOfStream]. Claims are recorded
///    only for committed decodes (no rollback path).
class _DecodeSink {
  final List<_WriteOp> ops = [];

  /// Committed coverage claims, `(start, end, tier)` over the record region.
  final List<(int, int, int)> claims = [];

  /// Blob demotions, `(start, end)`: extents a successful parse walked whose
  /// contents are not decoded — their [_tierSemantic] bytes fold down to
  /// [_tierStructural] (never up from [_tierUndecoded]).
  final List<(int, int)> demotions = [];

  /// Records a coverage tier claim over `[start, end)`.
  void claim(int start, int end, int tier) => claims.add((start, end, tier));

  /// Records a blob demotion over `[start, end)`.
  void demote(int start, int end) => demotions.add((start, end));

  int mark() => ops.length;

  void rollback(int m) {
    if (ops.length > m) ops.length = m;
  }

  /// Rolls back only the ops recorded at/after mark [m] whose offset is at or
  /// past [offsetBoundary] — used when a walk keeps a decoded PREFIX and
  /// discards the fields past it.
  void rollbackTailFrom(int m, int offsetBoundary) {
    var w = m;
    for (var r = m; r < ops.length; r++) {
      if (ops[r].offset < offsetBoundary) ops[w++] = ops[r];
    }
    ops.length = w;
  }

  /// Records a verbatim copy of `[from, to)` (source: struct by definition).
  void copy(int from, int to) {
    if (to > from) ops.add(_WriteOp.copy(from, to));
  }

  /// Records a pool reference (source: model by definition — the index
  /// round-trips through the mutable model pool).
  void poolRef(int at, int index) => ops.add(_WriteOp(at, _WirePrimitive.poolRef, _OpSource.model, index));

  /// Records a `u32` word of the given provenance.
  void u32(int at, int value, _OpSource source) => ops.add(_WriteOp(at, _WirePrimitive.u32, source, value));

  /// Records a single byte of the given provenance.
  void byte(int at, int value, _OpSource source) => ops.add(_WriteOp(at, _WirePrimitive.byte, source, value));

  /// Records an inline f64 value (source: model by definition).
  void f64(int at, double value) => ops.add(_WriteOp(at, _WirePrimitive.f64, _OpSource.model, 0, value));

  /// Records an inline i64 value (source: model by definition).
  void i64(int at, int value) => ops.add(_WriteOp(at, _WirePrimitive.i64, _OpSource.model, value));
}

/// The parsed WRITE MODEL of one binary TOF1 file: the retained container
/// header, the ordered (mutable) string pool, and the record-region write
/// plan whose typed ops re-serialize every decoded span from the model.
///
/// Obtained via [parseBinarySeqWriteModel]; [writeBody] re-emits the inflated
/// body (byte-exact for an unmutated model — corpus-gated 169/169) and
/// [writeFile] the whole TOF1 container. Mutations go through the model:
/// [replacePoolEntry] rewrites string content (names, expressions, comments —
/// the record region references the pool by index, so the references stay
/// valid), [replaceF64] rewrites inline numeric value slots.
class BinarySeqWriteModel {
  BinarySeqWriteModel._({
    required this.header,
    required this.headerHasSizeWord,
    required this.recordRegion,
    required this.pool,
    required this.poolEndsWithoutNul,
    required List<_WriteOp> plan,
  }) : _plan = plan;

  /// The container bytes before the zlib stream, retained verbatim. Its
  /// trailing `u32` (little-endian) is the inflated-body size field when
  /// [headerHasSizeWord] — re-emitted from the written body's length.
  final Uint8List header;

  /// Whether the header's final `u32` held the inflated-body length
  /// (corpus-measured: 169/169, right after the `PMCZ` marker).
  final bool headerHasSizeWord;

  /// The retained record-region bytes — the copy source for the plan's
  /// verbatim spans. Not written directly; the plan re-emits the region.
  /// A view over the model's freshly inflated body (exclusively owned by
  /// this model), so retaining it copies nothing.
  final Uint8List recordRegion;

  /// The ordered NUL string pool ([_orderedStringPool] of the body) — the
  /// MODEL the string region is written from, and the target of string
  /// mutations. Entries must stay Latin-1 (byte-valued code units).
  final List<String> pool;

  /// Whether the body ends WITHOUT a NUL after the last pool entry (the
  /// splitter tolerates both; the writer must reproduce the exact form).
  final bool poolEndsWithoutNul;

  final List<_WriteOp> _plan;

  int get recordRegionLength => recordRegion.length;

  /// The number of ops in the record-region write plan (diagnostics).
  int get planOpCount => _plan.length;

  int get _poolByteLength {
    var total = 0;
    for (final entry in pool) {
      total += entry.length + 1;
    }
    if (poolEndsWithoutNul && pool.isNotEmpty) total -= 1;
    return total;
  }

  /// The absolute body byte range `[start, end)` of pool entry [index]'s
  /// text (excluding its NUL), under the CURRENT pool contents.
  (int, int) poolEntryRange(int index) {
    var at = recordRegion.length;
    for (var i = 0; i < index; i++) {
      at += pool[i].length + 1;
    }
    return (at, at + pool[index].length);
  }

  /// Replaces every pool entry equal to [from] with [to]; returns how many
  /// entries changed. Record-region references are by pool INDEX, so they
  /// remain valid across the rewrite.
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

  /// Rewrites every inline f64 value slot currently holding [from] to [to];
  /// returns how many slots changed. Slots inside spans the writer copies
  /// verbatim are not reachable (they are not decoded value slots).
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

  /// The byte offsets of every inline f64 value slot in the plan holding
  /// [value] (mutation-probe diagnostics).
  List<int> f64Sites(double value) => [
    for (final op in _plan)
      if (op.primitive == _WirePrimitive.f64 && op.doubleValue == value) op.offset,
  ];

  /// Every inline f64 value in the plan, in plan order (mutation-target
  /// scouting).
  List<double> get f64Values => [
    for (final op in _plan)
      if (op.primitive == _WirePrimitive.f64) op.doubleValue,
  ];

  /// Re-serializes the inflated body: the record region from the write plan
  /// (typed ops from the model, verbatim copies from the retained bytes),
  /// then the string region from [pool].
  Uint8List writeBody() {
    final out = Uint8List(recordRegion.length + _poolByteLength);
    final view = ByteData.sublistView(out);
    for (final op in _plan) {
      // Wire dimension only: how the op's value is encoded, never why.
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

  /// Re-serializes the whole TOF1 file: the retained header (its size field
  /// re-emitted from the written body's length when present) followed by a
  /// zlib stream of [writeBody].
  ///
  /// The compressed bytes are NOT the original deflate stream: no Dart
  /// `ZLibCodec` parameter combination (level 0-9 × strategy 0-4 ×
  /// memLevel 1-9) reproduces NI's compressor output on any of the 169
  /// corpus binaries (first divergence at stream offset 5-6; Dart's stream
  /// is ~1% smaller at every level). The container is structurally
  /// reproduced instead — corpus-measured (169/169): a constant 1304-byte
  /// header ending in `PMCZ` + the u32-LE inflated-body size, a zlib
  /// stream (CMF/FLG 0x78 0x9C), and EOF exactly at the adler32 trailer.
  Uint8List writeFile() {
    final body = writeBody();
    // The codec's static type is `List<int>`; in practice it yields a
    // `Uint8List` — normalize once so [Uint8List.setRange] takes the
    // typed-data fast path instead of an element-by-element copy.
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

  /// The write-side scoreboard of this model's plan (see
  /// [BinaryWriteScoreboard]; computed by the [_planScoreboard] fold in
  /// seq_binary_metrics.dart).
  BinaryWriteScoreboard get scoreboard =>
      _planScoreboard(_plan, recordRegionBytes: recordRegion.length, poolBytes: _poolByteLength);
}

/// Emits the write ops of one old-format leaf property record
/// ([BinaryPropertyRecord]) from its fixed [_PropRecordField] geometry: the
/// lead/flags bytes and the kind code from the typed record
/// ([BinaryPropertyRecord.lead]/[BinaryPropertyRecord.flagsByte]/
/// [BinaryPropertyRecord.kind]), the verified framing zeros as grammar
/// constants, the type/name (and Str-family value) words as pool
/// references, Bool/Num values as typed value ops. The value/terminator
/// widths are re-derived from [BinaryPropertyRecord.length], which the
/// decoder set from exactly these consumption rules.
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
            ops.u32(valueAt, word, _OpSource.struct); // unresolvable index: retained raw
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
    // The trailing u16 zero terminator the scan verified byte-for-byte.
    ops.byte(o + consumed, 0, _OpSource.grammar);
    ops.byte(o + consumed + 1, 0, _OpSource.grammar);
  }
}

/// Locates the container's zlib stream and inflates it — the shared core of
/// [inflateBinaryBody], additionally returning the stream's byte offset (the
/// header length) for the writer's container model.
(int, Uint8List)? _locateAndInflateBody(Uint8List bytes) {
  if (detectSeqFormat(bytes) != SeqFormat.binary) return null;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] != _zlibCmf) continue;
    if (!ZlibFlag.isKnown(bytes[i + 1])) continue;
    try {
      final out = _inflateCapped(Uint8List.sublistView(bytes, i));
      if (out != null && out.length > _minInflatedBytes) return (i, out);
    } catch (_) {
      // Keep scanning past a position that does not start a valid stream.
    }
  }
  return null;
}

/// Parses [seqBytes] into a [BinarySeqWriteModel], or null when it is not an
/// inflatable binary TOF1 file. The record-region write plan is captured by
/// the production decode passes (the [_decodeBody] recording); bytes no
/// decode claims become verbatim copy spans, so [writeBody] is byte-exact by
/// construction for every file the decoder can inflate — including bodies
/// that do not frame at all (a single copy span).
BinarySeqWriteModel? parseBinarySeqWriteModel(Uint8List seqBytes) {
  final located = _locateAndInflateBody(seqBytes);
  if (located == null) return null;
  final (streamAt, body) = located;
  // The header is retained as an owned copy so the model does not pin the
  // whole input buffer; the body is freshly inflated (exclusively owned).
  final header = seqBytes.sublist(0, streamAt);
  final hasSizeWord =
      streamAt >= _u32Bytes &&
      ByteData.sublistView(seqBytes).getUint32(streamAt - _u32Bytes, Endian.little) == body.length;

  // One decode bundle: boundary, pool, and write ops come from the same
  // [_decodeBody] pass (no second pool split, no second decode walk).
  final decoded = _decodeBody(body);
  if (decoded == null) {
    // No framed string region: the whole body is one retained copy span.
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
    // A view, not a copy: the freshly inflated body is exclusively owned by
    // this model (nothing else retains it), so the record region borrows it.
    recordRegion: Uint8List.sublistView(body, 0, decoded.boundary),
    pool: decoded.pool,
    poolEndsWithoutNul: body.isNotEmpty && body[body.length - 1] != 0,
    plan: _buildWritePlan(decoded.stream.ops, decoded.boundary),
  );
}

/// Builds a covering, non-overlapping write plan over `[0, boundary)` from
/// the captured ops: stable-sorted by offset (first-recorded wins a tie), a
/// cursor walk drops ops overlapping an already-planned span, and every gap
/// becomes a verbatim copy op. Because every captured op re-emits exactly
/// the bytes it was read from, dropping an overlapped duplicate never
/// changes the output.
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
    if (op.offset < cursor) continue; // overlaps a committed op — duplicate
    final end = op.offset + op.length;
    if (end > boundary) continue;
    if (op.offset > cursor) plan.add(_WriteOp.copy(cursor, op.offset));
    plan.add(op);
    cursor = end;
  }
  if (cursor < boundary) plan.add(_WriteOp.copy(cursor, boundary));
  return plan;
}
