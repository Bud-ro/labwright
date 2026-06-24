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

  // Pin the full-corpus block-diagram object count for each catalogued BD kind, so
  // a doc "Corpus: N" figure (or a decode change) can't silently rot. This is the
  // guard that was missing when review9's SAMPLE counts slipped into the catalog
  // docs 3-6x too low. ±20% band tolerates a corpus refetch / minor decode shift
  // but catches the multiples-off failure mode. Update the pin AND the matching
  // catalog doc together when the corpus or decode legitimately changes.
  test('catalogued BD object kinds hold their full-corpus counts (anti-rot)', () {
    const expected = <int, int>{
      0x2f: 44395, 0x31: 31995, 0x63: 13737, 0x8c: 6620, 0x3a: 3479, 0xd6: 2209,
      0x32: 2075, 0xc5: 1518, 0x104: 2155, 0x44: 3228, 0x3e: 1961, 0x34: 1665, 0xa9: 2416,
      0x2c: 14563, 0x20: 4892, 0x21: 1654, 0x16: 41830, 0x95: 16118, 0x177: 17043,
      0x93: 1479, 0x172: 1409, 0x6c: 1020, 0x36: 1002, 0xcd: 1186, 0x14d: 896,
      0x55: 2234, 0x153: 1466, 0x4e: 947,
    };
    final counts = {for (final k in expected.keys) k: 0};
    for (final root in ['/tmp/claude-1000/vi_samples', '/tmp/claude-1000/vi_diverse']) {
      final d = Directory(root);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.vi')) continue;
        try {
          final vi = buildViModel(f.readAsBytesSync());
          for (final o in vi.blockDiagrams.expand((x) => x.objects)) {
            if (counts.containsKey(o.kind)) counts[o.kind] = counts[o.kind]! + 1;
          }
        } catch (_) {}
      }
    }
    expected.forEach((kind, exp) {
      expect(counts[kind]!, inInclusiveRange((exp * 0.8).floor(), (exp * 1.2).ceil()),
          reason: 'BD kind 0x${kind.toRadixString(16)} count ${counts[kind]} is >20% off the pinned $exp '
              '— update the catalog doc + this pin if the corpus/decode legitimately changed.');
    });
  });
}
