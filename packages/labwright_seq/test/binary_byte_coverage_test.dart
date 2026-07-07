@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The binary decode campaign's byte-level scoreboard ([binaryByteCoverage]):
/// every inflated body byte is accounted to pool / record-region semantic /
/// structural / undecoded. These tests pin the accounting INVARIANTS (the
/// tiers always sum to the region; the undecoded-span map agrees with the
/// counter) and FLOORS for the decoded fractions, so a decode regression or
/// a metric drift fails loudly while genuine decode progress passes.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary byte coverage (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final oracle = File('${corpusSeqDir.path}/rosetta/OutputVoltage_BIN.seq');

  test('oracle: tiers sum to the region and the span map agrees', () {
    final bytes = Uint8List.fromList(oracle.readAsBytesSync());
    final cov = binaryByteCoverage(bytes)!;
    expect(cov.recordSemanticBytes + cov.recordStructuralBytes + cov.recordUndecodedBytes, cov.recordRegionBytes);
    expect(cov.recordRegionBytes + cov.poolBytes, cov.bodyBytes);
    final spanTotal = binaryUndecodedSpans(bytes, max: 1 << 30).fold(0, (sum, s) => sum + (s.$2 - s.$1));
    expect(spanTotal, cov.recordUndecodedBytes);
  });

  test('oracle: decoded floors (record-region semantic >= 70%)', () {
    final cov = binaryByteCoverage(Uint8List.fromList(oracle.readAsBytesSync()))!;
    // Measured 2026-07 round 3 (sequence-record walk: group arrays,
    // scalar/expression array elements, elemproto tails): semantic
    // 71.5%, accounted 99.0%. Floors slightly under the measurement.
    expect(cov.recordSemanticRatio, greaterThanOrEqualTo(0.70));
    expect(cov.recordAccountedRatio, greaterThanOrEqualTo(0.985));
  });

  test('rosetta binaries: invariants hold and each decodes >= 55% of its record region', () {
    for (final f in Directory('${corpusSeqDir.path}/rosetta').listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final cov = binaryByteCoverage(bytes);
      expect(cov, isNotNull, reason: f.path);
      expect(
        cov!.recordSemanticBytes + cov.recordStructuralBytes + cov.recordUndecodedBytes,
        cov.recordRegionBytes,
        reason: f.path,
      );
      // Round-3 measurement: every rosetta binary decodes >= 71.5% of its
      // record region semantically (the full sequence-record walk closed
      // the step-content gap).
      expect(cov.recordSemanticRatio, greaterThanOrEqualTo(0.70), reason: f.path);
    }
  });

  test('whole corpus: per-file invariants and the aggregate floor', () {
    var total = const BinaryByteCoverage(
      bodyBytes: 0,
      poolBytes: 0,
      recordSemanticBytes: 0,
      recordStructuralBytes: 0,
    );
    var files = 0;
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final cov = binaryByteCoverage(bytes);
      if (cov == null) continue;
      expect(cov.recordUndecodedBytes, greaterThanOrEqualTo(0), reason: f.path);
      expect(cov.recordRegionBytes, greaterThan(0), reason: f.path);
      files++;
      total = total + cov;
    }
    // Measured 2026-07 on the clean 169-binary corpus: record region
    // 23.1 MB, semantic 32.4%, structural 8.1% — the campaign scoreboard
    // (the earlier 294-file corpus measured 30.2%/7.7% before the leaked
    // SandeepKumarK098 source was purged; the ratios shifted mechanically
    // with the corpus, not from a decode change). Floors under-pin
    // slightly.
    expect(files, greaterThanOrEqualTo(165));
    expect(total.recordSemanticRatio, greaterThanOrEqualTo(0.32));
    expect(total.recordAccountedRatio, greaterThanOrEqualTo(0.40));
  });
}
