/// Byte accounting of a `TOF1` body against the record grammar.
library;

import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_binary_grammar.dart';
import 'seq_binary_header.dart';

/// How many of a body's bytes the grammar decodes, frames, or leaves undecoded.
class BinaryByteCoverage {
  const BinaryByteCoverage({
    required this.bodyBytes,
    required this.poolBytes,
    required this.recordSemanticBytes,
    required this.recordStructuralBytes,
    this.poolTailBytes = 0,
  });

  final int bodyBytes;

  /// The pool count word and the strings after it.
  final int poolBytes;

  /// Bytes after the last pool string, not yet decoded (see [BinaryUndecodedField.poolTail]).
  final int poolTailBytes;

  /// Record-region bytes carrying model content.
  final int recordSemanticBytes;

  /// Record-region framing: flag words, counts, null markers, the terminator.
  final int recordStructuralBytes;

  int get recordRegionBytes => bodyBytes - poolBytes - poolTailBytes;

  /// Record-region bytes whose purpose is not yet decoded (see [BinaryUndecodedField]).
  int get recordUndecodedBytes => recordRegionBytes - recordSemanticBytes - recordStructuralBytes;

  double get recordSemanticRatio => recordRegionBytes == 0 ? 0 : recordSemanticBytes / recordRegionBytes;

  double get recordAccountedRatio =>
      recordRegionBytes == 0 ? 0 : (recordSemanticBytes + recordStructuralBytes) / recordRegionBytes;

  double get bodySemanticRatio => bodyBytes == 0 ? 0 : (recordSemanticBytes + poolBytes) / bodyBytes;

  double get bodyAccountedRatio => bodyBytes == 0 ? 0 : (bodyBytes - recordUndecodedBytes - poolTailBytes) / bodyBytes;

  BinaryByteCoverage operator +(BinaryByteCoverage other) => BinaryByteCoverage(
    bodyBytes: bodyBytes + other.bodyBytes,
    poolBytes: poolBytes + other.poolBytes,
    recordSemanticBytes: recordSemanticBytes + other.recordSemanticBytes,
    recordStructuralBytes: recordStructuralBytes + other.recordStructuralBytes,
    poolTailBytes: poolTailBytes + other.poolTailBytes,
  );

  @override
  String toString() =>
      'BinaryByteCoverage(body=$bodyBytes, pool=$poolBytes, semantic=$recordSemanticBytes, '
      'structural=$recordStructuralBytes, undecoded=$recordUndecodedBytes, poolTail=$poolTailBytes)';
}

/// Body coverage of a `TOF1` file; null when the body does not inflate or leaves the grammar.
BinaryByteCoverage? binaryByteCoverage(Uint8List seqBytes) {
  final grammar = decodeTof1(seqBytes)?.grammar;
  return grammar == null ? null : bodyByteCoverage(grammar);
}

BinaryByteCoverage bodyByteCoverage(Tof1Body body) {
  var semantic = 0;
  var structural = 0;
  final region = body.recordRegionLength;
  final tiers = body.tiers;
  for (var i = 0; i < region; i++) {
    final tier = tiers[i];
    if (tier == BinaryByteTier.semantic.index) {
      semantic++;
    } else if (tier == BinaryByteTier.structural.index) {
      structural++;
    }
  }
  final tail = body.poolTail.length;
  return BinaryByteCoverage(
    bodyBytes: body.bytes.length,
    poolBytes: body.bytes.length - region - tail,
    recordSemanticBytes: semantic,
    recordStructuralBytes: structural,
    poolTailBytes: tail,
  );
}

/// The body fields the grammar reads but cannot yet name.
enum BinaryUndecodedField {
  /// The word after a typedef entry's flags.
  typeEntryWord,

  /// The word after a record's flags; the parse stops when it is nonzero.
  recordFlagsHigh,

  /// The word before an `Enum` typedef's items array.
  enumItemsWord,

  /// The word between the data root and the `0xffffffff` terminator.
  bodyTailWord,

  /// Bytes after the last pool string.
  poolTail,
}

/// A body span of [BinaryByteTier.undecoded] bytes.
typedef BinaryUndecodedSpan = ({int start, int end, BinaryUndecodedField field});

/// Every undecoded span of the body, in offset order, with the field it belongs to.
List<BinaryUndecodedSpan> binaryUndecodedSpans(Tof1Body body) {
  final spans = <BinaryUndecodedSpan>[];
  for (final type in body.types) {
    spans.add((start: type.offset + 4, end: type.offset + 8, field: BinaryUndecodedField.typeEntryWord));
    _recordSpans(type.root, spans, isTypeRoot: true);
  }
  _recordSpans(body.data, spans, isTypeRoot: false);
  spans.add((start: body.data.end, end: body.data.end + 4, field: BinaryUndecodedField.bodyTailWord));
  if (body.poolTail.isNotEmpty) {
    spans.add((
      start: body.bytes.length - body.poolTail.length,
      end: body.bytes.length,
      field: BinaryUndecodedField.poolTail,
    ));
  }
  spans.sort((a, b) => a.start.compareTo(b.start));
  return spans;
}

void _recordSpans(BinaryRecord record, List<BinaryUndecodedSpan> spans, {required bool isTypeRoot}) {
  if (!isTypeRoot) {
    spans.add((start: record.offset + 4, end: record.offset + 8, field: BinaryUndecodedField.recordFlagsHigh));
  }
  final items = record.enumItems;
  if (items != null) {
    spans.add((start: items.offset - 4, end: items.offset, field: BinaryUndecodedField.enumItemsWord));
    _recordSpans(items, spans, isTypeRoot: false);
  }
  final proto = record.elemProto;
  if (proto != null) _recordSpans(proto, spans, isTypeRoot: false);
  for (final element in record.elements ?? const <Object?>[]) {
    if (element is BinaryRecord) _recordSpans(element, spans, isTypeRoot: false);
  }
  for (final block in [record.attributes, record.typeAttributes]) {
    if (block != null) _recordSpans(block, spans, isTypeRoot: false);
  }
  for (final child in record.children) {
    _recordSpans(child, spans, isTypeRoot: false);
  }
}

/// Header bytes by purpose: `(decoded, plumbing)` where plumbing is zero padding and reserved zero ranges.
(int, int) headerByteCoverage(Uint8List seqBytes) {
  var decoded = 0;
  var plumbing = 0;
  for (final (start, end, isDecoded) in Tof1Header.classify(seqBytes)) {
    if (isDecoded) {
      decoded += end - start;
    } else {
      plumbing += end - start;
    }
  }
  return (decoded, plumbing);
}
