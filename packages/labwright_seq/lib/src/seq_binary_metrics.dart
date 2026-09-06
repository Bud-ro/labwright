part of 'seq_binary.dart';

const _tierUndecoded = 0;

const _tierStructural = 1;

const _tierSemantic = 2;

Uint8List _tiersOfStream(_RecordingDecodeSink stream, int recordRegionLength) {
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

class BinaryByteCoverage {
  const BinaryByteCoverage({
    required this.bodyBytes,
    required this.poolBytes,
    required this.recordSemanticBytes,
    required this.recordStructuralBytes,
  });

  final int bodyBytes;

  final int poolBytes;

  final int recordSemanticBytes;

  final int recordStructuralBytes;

  int get recordRegionBytes => bodyBytes - poolBytes;

  int get recordUndecodedBytes => recordRegionBytes - recordSemanticBytes - recordStructuralBytes;

  double get recordSemanticRatio => recordRegionBytes == 0 ? 0 : recordSemanticBytes / recordRegionBytes;

  double get recordAccountedRatio =>
      recordRegionBytes == 0 ? 0 : (recordSemanticBytes + recordStructuralBytes) / recordRegionBytes;

  double get bodySemanticRatio => bodyBytes == 0 ? 0 : (recordSemanticBytes + poolBytes) / bodyBytes;

  double get bodyAccountedRatio => bodyBytes == 0 ? 0 : (bodyBytes - recordUndecodedBytes) / bodyBytes;

  BinaryByteCoverage operator +(BinaryByteCoverage other) => BinaryByteCoverage(
    bodyBytes: bodyBytes + other.bodyBytes,
    poolBytes: poolBytes + other.poolBytes,
    recordSemanticBytes: recordSemanticBytes + other.recordSemanticBytes,
    recordStructuralBytes: recordStructuralBytes + other.recordStructuralBytes,
  );
}

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

class BinaryWriteScoreboard {
  const BinaryWriteScoreboard({
    required this.bodyBytes,
    required this.poolBytes,
    required this.modelBytes,
    required this.grammarBytes,
    required this.structuralBytes,
    required this.copiedBytes,
  });

  final int bodyBytes;

  final int poolBytes;

  final int modelBytes;

  final int grammarBytes;

  final int structuralBytes;

  final int copiedBytes;

  int get recordRegionBytes => bodyBytes - poolBytes;

  int get fromModelBytes => modelBytes + grammarBytes;

  double get recordModelRatio => recordRegionBytes == 0 ? 0 : fromModelBytes / recordRegionBytes;

  double get bodyModelRatio => bodyBytes == 0 ? 0 : (fromModelBytes + poolBytes) / bodyBytes;

  double get bodyCopiedRatio => bodyBytes == 0 ? 0 : copiedBytes / bodyBytes;

  BinaryWriteScoreboard operator +(BinaryWriteScoreboard other) => BinaryWriteScoreboard(
    bodyBytes: bodyBytes + other.bodyBytes,
    poolBytes: poolBytes + other.poolBytes,
    modelBytes: modelBytes + other.modelBytes,
    grammarBytes: grammarBytes + other.grammarBytes,
    structuralBytes: structuralBytes + other.structuralBytes,
    copiedBytes: copiedBytes + other.copiedBytes,
  );

  @override
  String toString() =>
      'BinaryWriteScoreboard(body=$bodyBytes, pool=$poolBytes, '
      'model=$modelBytes, grammar=$grammarBytes, structural=$structuralBytes, copied=$copiedBytes, '
      'recordModel=${(recordModelRatio * 100).toStringAsFixed(1)}%, '
      'bodyModel=${(bodyModelRatio * 100).toStringAsFixed(1)}%)';
}

BinaryWriteScoreboard _planScoreboard(List<_WriteOp> plan, {required int recordRegionBytes, required int poolBytes}) {
  var model = 0, grammar = 0, structural = 0, copied = 0;
  for (final op in plan) {
    if (op.primitive == _WirePrimitive.copy) {
      copied += op.length;
      continue;
    }
    switch (op.source) {
      case _OpSource.struct:
        structural += op.length;
      case _OpSource.model:
        model += op.length;
      case _OpSource.grammar:
        grammar += op.length;
    }
  }
  return BinaryWriteScoreboard(
    bodyBytes: recordRegionBytes + poolBytes,
    poolBytes: poolBytes,
    modelBytes: model,
    grammarBytes: grammar,
    structuralBytes: structural,
    copiedBytes: copied,
  );
}
