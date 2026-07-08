part of 'seq_binary.dart';

// ─────────────── decode metrics: pure folds of the recorded stream ───────────────
//
// Every binary-decode metric — the byte-coverage tier accounting, the
// undecoded-span census, and the writer scoreboard — is computed HERE, as a
// pure fold of the typed decode stream one production pass records into a
// [_DecodeSink] (see [_decodeBody]). The parsers emit only that stream;
// nothing in this file re-reads body bytes. The writer serializes from the
// SAME stream ([_buildWritePlan] over [_DecodeSink.ops]), so the coverage
// tiers and the writer's copy-vs-serialize splits cannot drift apart.

/// Per-byte accounting tiers for the record region (see [BinaryByteCoverage]).
/// Higher wins when decode claims overlap.
const _tierUndecoded = 0;

/// Extent walked by a measured shape, contents not decoded (element-type spec
/// blobs, extdata block payloads, the inter-record preamble, the leading recon
/// words).
const _tierStructural = 1;

/// Consumed by a twin-validated decode (type heads/bodies, sequence records,
/// step references, module pairs, leaf property records, …).
const _tierSemantic = 2;

/// Folds a recorded decode stream's tier claims into the per-byte tier map of
/// a record region of [recordRegionLength] bytes.
///
/// Claims never downgrade (a byte two decodes claim keeps the higher tier);
/// demotions then downgrade [_tierSemantic] bytes to [_tierStructural] — the
/// blob extents a successful parse walked whose contents are not decoded.
/// Bytes outside any committed claim stay [_tierUndecoded]: a blob demotion
/// can never upgrade bytes nothing accounts for. Spans are clamped to the
/// region, so an oversized claim cannot mark past it.
Uint8List _tiersOfStream(_DecodeSink stream, int recordRegionLength) {
  final tiers = Uint8List(recordRegionLength);
  for (final (start, end, tier) in stream.claims) {
    final from = start < 0 ? 0 : start;
    final to = end > recordRegionLength ? recordRegionLength : end;
    for (var i = from; i < to; i++) {
      if (tiers[i] < tier) tiers[i] = tier;
    }
  }
  for (final (start, end) in stream.demotions) {
    final from = start < 0 ? 0 : start;
    final to = end > recordRegionLength ? recordRegionLength : end;
    for (var i = from; i < to; i++) {
      if (tiers[i] == _tierSemantic) tiers[i] = _tierStructural;
    }
  }
  return tiers;
}

/// How much of a binary TOF1 file's **inflated body bytes** the decoder
/// accounts for — the byte-level scoreboard of the binary decode campaign
/// (the analog of the RSRC heap-body tiering; [SeqCoverage] is the
/// node-level metric for the parsed tree).
///
/// Every inflated-body byte lands in exactly one bucket:
///
///  * **pool** ([poolBytes]) — the string region: the ordered NUL-terminated
///    string pool. Its structure and contents are fully read
///    ([_orderedStringPool] is total over the region: every byte is string
///    content or a NUL separator), and every decoded record resolves its
///    names/values through it by index — twin-validated through every decoded
///    value. Reported as its own bucket so the record-region numbers cannot
///    be flattered by pool mass.
///  * **record-region semantic** ([recordSemanticBytes]) — consumed by a
///    twin-validated decode: type-record heads and decoded bodies, sequence
///    declarations/records, leading/tail subprops, step references and their
///    `TS` nodes, module name→value pairs, and old-format leaf property
///    records.
///  * **record-region structural** ([recordStructuralBytes]) — extent walked
///    by a measured shape, contents deliberately not decoded: element-type
///    spec blobs ([BinaryTypeField.elementSpecBytes]), extdata block
///    payloads, the fixed inter-record preamble ([_typeRecordPreambleBytes]),
///    the leading recon words, and the undecoded head word of word-4-triple
///    type records.
///  * **record-region undecoded** ([recordUndecodedBytes]) — everything else:
///    bytes no decode claims. The campaign drives this to zero.
class BinaryByteCoverage {
  const BinaryByteCoverage({
    required this.bodyBytes,
    required this.poolBytes,
    required this.recordSemanticBytes,
    required this.recordStructuralBytes,
  });

  /// Total inflated-body size in bytes.
  final int bodyBytes;

  /// String-region (ordered NUL string pool) bytes — fully read; see class doc.
  final int poolBytes;

  /// Record-region bytes consumed by twin-validated decodes.
  final int recordSemanticBytes;

  /// Record-region bytes whose extent is walked but contents undecoded.
  final int recordStructuralBytes;

  /// Record-region size ([bodyBytes] − [poolBytes]).
  int get recordRegionBytes => bodyBytes - poolBytes;

  /// Record-region bytes nothing accounts for — the true gap.
  int get recordUndecodedBytes => recordRegionBytes - recordSemanticBytes - recordStructuralBytes;

  /// Decoded fraction of the record region alone (the hard number).
  double get recordSemanticRatio => recordRegionBytes == 0 ? 0 : recordSemanticBytes / recordRegionBytes;

  /// Accounted (semantic + structural) fraction of the record region.
  double get recordAccountedRatio =>
      recordRegionBytes == 0 ? 0 : (recordSemanticBytes + recordStructuralBytes) / recordRegionBytes;

  /// Decoded fraction of the whole body (record-region semantic + pool).
  double get bodySemanticRatio => bodyBytes == 0 ? 0 : (recordSemanticBytes + poolBytes) / bodyBytes;

  /// Accounted fraction of the whole body (everything but [recordUndecodedBytes]).
  double get bodyAccountedRatio => bodyBytes == 0 ? 0 : (bodyBytes - recordUndecodedBytes) / bodyBytes;

  /// Aggregation over a corpus.
  BinaryByteCoverage operator +(BinaryByteCoverage other) => BinaryByteCoverage(
    bodyBytes: bodyBytes + other.bodyBytes,
    poolBytes: poolBytes + other.poolBytes,
    recordSemanticBytes: recordSemanticBytes + other.recordSemanticBytes,
    recordStructuralBytes: recordStructuralBytes + other.recordStructuralBytes,
  );
}

/// Measures [BinaryByteCoverage] for a binary TOF1 `.seq` — every inflated
/// body byte accounted to pool / semantic / structural / undecoded (see the
/// class doc for the tier definitions and what marks each), folded from the
/// recorded decode stream. Returns null when [seqBytes] is not an inflatable
/// binary file or the body does not frame.
BinaryByteCoverage? binaryByteCoverage(Uint8List seqBytes) {
  final decoded = _decodeSeq(seqBytes);
  if (decoded == null) return null;
  final tiers = _tiersOfStream(decoded.stream, decoded.boundary);
  var semantic = 0;
  var structural = 0;
  for (final tier in tiers) {
    if (tier == _tierSemantic) {
      semantic++;
    } else if (tier == _tierStructural) {
      structural++;
    }
  }
  return BinaryByteCoverage(
    bodyBytes: decoded.body.length,
    poolBytes: decoded.body.length - decoded.boundary,
    recordSemanticBytes: semantic,
    recordStructuralBytes: structural,
  );
}

/// The UNDECODED record-region byte spans of a binary TOF1 file, as
/// `(start, end)` offsets into the inflated body, largest-first capped to
/// [max] — the diagnostic map of where [BinaryByteCoverage.recordUndecodedBytes]
/// mass sits (point the prober at the biggest spans). Returns `[]` when the
/// file is not an inflatable binary or does not frame.
List<(int, int)> binaryUndecodedSpans(Uint8List seqBytes, {int max = 50}) {
  final decoded = _decodeSeq(seqBytes);
  if (decoded == null) return const [];
  final tiers = _tiersOfStream(decoded.stream, decoded.boundary);
  final spans = <(int, int)>[];
  var start = -1;
  for (var i = 0; i <= tiers.length; i++) {
    final undecoded = i < tiers.length && tiers[i] == _tierUndecoded;
    if (undecoded && start < 0) start = i;
    if (!undecoded && start >= 0) {
      spans.add((start, i));
      start = -1;
    }
  }
  spans.sort((a, b) => (b.$2 - b.$1).compareTo(a.$2 - a.$1));
  return spans.length > max ? spans.sublist(0, max) : spans;
}

/// The writer scoreboard for one file (or, summed with [+], a corpus): how
/// many inflated-body bytes were written FROM THE MODEL versus re-emitted
/// from retained structure versus copied verbatim — the writer-side mirror
/// of [BinaryByteCoverage].
class BinaryWriteScoreboard {
  const BinaryWriteScoreboard({
    required this.bodyBytes,
    required this.poolBytes,
    required this.modelBytes,
    required this.structuralBytes,
    required this.copiedBytes,
  });

  /// Total inflated-body size in bytes.
  final int bodyBytes;

  /// String-region bytes — always written from the model pool.
  final int poolBytes;

  /// Record-region bytes emitted from model content (pool references,
  /// counts, type refs, head fields, inline f64/i64/bool values).
  final int modelBytes;

  /// Record-region bytes re-emitted from retained wire structure (flags,
  /// attr words, delimiters, zeros, pads).
  final int structuralBytes;

  /// Record-region bytes copied verbatim (undecoded spans, spec/extdata
  /// blobs, inter-record preambles).
  final int copiedBytes;

  int get recordRegionBytes => bodyBytes - poolBytes;

  /// Model-written fraction of the record region.
  double get recordModelRatio => recordRegionBytes == 0 ? 0 : modelBytes / recordRegionBytes;

  /// Model-written fraction of the whole body (pool counts as model).
  double get bodyModelRatio => bodyBytes == 0 ? 0 : (modelBytes + poolBytes) / bodyBytes;

  /// Copied-verbatim fraction of the whole body.
  double get bodyCopiedRatio => bodyBytes == 0 ? 0 : copiedBytes / bodyBytes;

  BinaryWriteScoreboard operator +(BinaryWriteScoreboard other) => BinaryWriteScoreboard(
    bodyBytes: bodyBytes + other.bodyBytes,
    poolBytes: poolBytes + other.poolBytes,
    modelBytes: modelBytes + other.modelBytes,
    structuralBytes: structuralBytes + other.structuralBytes,
    copiedBytes: copiedBytes + other.copiedBytes,
  );

  @override
  String toString() =>
      'BinaryWriteScoreboard(body=$bodyBytes, pool=$poolBytes, '
      'model=$modelBytes, structural=$structuralBytes, copied=$copiedBytes, '
      'recordModel=${(recordModelRatio * 100).toStringAsFixed(1)}%, '
      'bodyModel=${(bodyModelRatio * 100).toStringAsFixed(1)}%)';
}

/// Folds a record-region write [plan] into its [BinaryWriteScoreboard]:
/// each op's bytes accounted to the model / structural / copied split its
/// [_WriteOpKind] declares, plus the pool region ([poolBytes], always
/// model-written) on top of the record region.
BinaryWriteScoreboard _planScoreboard(List<_WriteOp> plan, {required int recordRegionBytes, required int poolBytes}) {
  var model = 0, structural = 0, copied = 0;
  for (final op in plan) {
    switch (op.kind) {
      case _WriteOpKind.copy:
        copied += op.length;
      case _WriteOpKind.structU32 || _WriteOpKind.structByte:
        structural += op.length;
      case _WriteOpKind.poolRef ||
          _WriteOpKind.modelU32 ||
          _WriteOpKind.f64 ||
          _WriteOpKind.i64 ||
          _WriteOpKind.boolByte:
        model += op.length;
    }
  }
  return BinaryWriteScoreboard(
    bodyBytes: recordRegionBytes + poolBytes,
    poolBytes: poolBytes,
    modelBytes: model,
    structuralBytes: structural,
    copiedBytes: copied,
  );
}
