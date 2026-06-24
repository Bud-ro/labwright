@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

/// Mechanical regression guard over the pinned diverse corpus (corpus/README.md).
///
/// Skipped automatically when the corpus is not fetched (so it never breaks CI);
/// run locally after `corpus/fetch.sh`. The "% deliberately parsed" floor is NOT
/// hand-maintained: `tool/coverage.dart` measures it and writes
/// `corpus/baseline.json`; this test reads that figure and asserts the current
/// run is at or above it — so the metric can only ratchet UP. Re-run the tool to
/// record an improvement; a drop fails the test.
const _heapTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

void main() {
  final dir = Directory('/tmp/claude-1000/vi_samples');
  if (!dir.existsSync()) {
    test('corpus deliberately-parsed (skipped: corpus not fetched — run corpus/fetch.sh)', () {}, skip: true);
    return;
  }

  final sample = (dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path)))
      .take(60)
      .toList();

  test('every corpus VI parses and decodes without throwing (totality)', () {
    for (final f in sample) {
      final bytes = f.readAsBytesSync();
      expect(() => parseVi(bytes), returnsNormally, reason: f.path);
      expect(() => decodeSections(bytes), returnsNormally, reason: f.path);
    }
  });

  test('"% deliberately parsed" holds at or above the machine-written baseline', () {
    var framed = 0, body = 0;
    for (final f in sample) {
      for (final s in decodeSections(f.readAsBytesSync())) {
        if (!_heapTags.contains(s.tag) || s.bytes.length < 6) continue;
        final w = walkHeapBody(s.bytes);
        framed += w.coveredBytes;
        body += w.bodyBytes;
      }
    }
    expect(body, greaterThan(0));
    final current = framed / body;

    final baselineFile = File('../../corpus/baseline.json');
    final floor = baselineFile.existsSync()
        ? ((jsonDecode(baselineFile.readAsStringSync()) as Map)['picotechFirst60']
            as Map)['deliberatelyParsed'] as num
        : 0.0;
    expect(current, greaterThanOrEqualTo(floor - 0.001),
        reason: 'deliberately-parsed regressed to ${(current * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.');
  });
}
