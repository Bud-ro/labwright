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

  // The diverse corpus exercises the heap walker/decoders on the most
  // heterogeneous bytes — guard TOTALITY there too (the most likely place a
  // walk-desync or unguarded index would throw). Deterministic first-200 slice.
  test('a vi_diverse slice parses/decodes/walks without throwing (totality)', () {
    final dd = Directory('/tmp/claude-1000/vi_diverse');
    if (!dd.existsSync()) return; // diverse set not fetched — skip silently
    final diverse = (dd
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.vi'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path)))
        .take(200)
        .toList();
    // Also count the newest decodes so a silently-dropped id/path fails loudly
    // (they're a tiny byte-fraction, below the semantic-floor tolerance).
    var propertyNames = 0, helpStrings = 0, controlF64 = 0;
    for (final f in diverse) {
      final bytes = f.readAsBytesSync();
      expect(() {
        parseVi(bytes);
        for (final s in decodeSections(bytes)) {
          if (!_heapTags.contains(s.tag) || s.bytes.length < 6) continue;
          final w = walkHeapBody(s.bytes);
          for (final span in w.spans) {
            // every framed span must be in-bounds and classifiable
            expect(span.offset + span.length, lessThanOrEqualTo(s.bytes.length));
            heapDecodeTier(s.bytes, span.offset, span.lead, s.tag);
            final a = decodeHeapAttr(s.bytes, span.offset);
            if (a == null) continue;
            if (a.attribute == HeapAttribute.propertyName) {
              propertyNames++;
            }
            if (a.attribute == HeapAttribute.helpDescription && a.asString != null && a.asString!.isNotEmpty) {
              helpStrings++;
            }
            if ((a.attribute == HeapAttribute.foregroundColor || a.attribute == HeapAttribute.foregroundColorB) &&
                a.width == HeapAttrWidth.f64) {
              controlF64++;
            }
          }
        }
      }, returnsNormally, reason: f.path);
    }
    // These ids exist in the diverse corpus; >0 guards against a dropped decoder.
    expect(propertyNames, greaterThan(0), reason: 'propertyName (0x31) decode dropped');
    expect(helpStrings, greaterThan(0), reason: 'helpDescription (0x6c) string decode dropped');
    expect(controlF64, greaterThan(0), reason: '0x20/0x21 control-min/max f64 decode dropped');
  });

  test('"% deliberately parsed" AND "% semantically decoded" hold at or above baseline', () {
    var framed = 0, body = 0, semantic = 0;
    for (final f in sample) {
      for (final s in decodeSections(f.readAsBytesSync())) {
        if (!_heapTags.contains(s.tag) || s.bytes.length < 6) continue;
        final w = walkHeapBody(s.bytes);
        framed += w.coveredBytes;
        body += w.bodyBytes;
        for (final span in w.spans) {
          if (heapDecodeTier(s.bytes, span.offset, span.lead, s.tag) == HeapDecodeTier.semantic) {
            semantic += span.length;
          }
        }
      }
    }
    expect(body, greaterThan(0));

    final baselineFile = File('../../corpus/baseline.json');
    final base = baselineFile.existsSync()
        ? (jsonDecode(baselineFile.readAsStringSync()) as Map)['picotechFirst60'] as Map
        : const <String, Object?>{};
    num floor(String k) => (base[k] as num?) ?? 0.0;

    final framedPct = framed / body;
    expect(framedPct, greaterThanOrEqualTo(floor('deliberatelyParsed') - 0.001),
        reason: 'deliberately-parsed regressed to ${(framedPct * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor('deliberatelyParsed') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.');

    // The semantic frontier is the surface the new decoders move; guard it too so
    // a dropped attribute id / ref subop / isDecoded flag fails the test.
    final semanticPct = semantic / body;
    expect(semanticPct, greaterThanOrEqualTo(floor('semanticallyDecoded') - 0.001),
        reason: 'semantically-decoded regressed to ${(semanticPct * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor('semanticallyDecoded') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.');
  });
}
