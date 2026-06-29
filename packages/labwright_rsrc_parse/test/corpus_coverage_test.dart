@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Mechanical regression guard over the pinned diverse corpus (corpus/README.md).
///
/// Skipped automatically when the corpus is not fetched (so it never breaks CI);
/// run locally after `tool/fetch_corpus.dart`. The "% deliberately parsed" floor
/// is NOT hand-maintained: `tool/coverage.dart` measures it over the WHOLE corpus
/// and writes `corpus/baseline.json`; this test reads that figure and asserts the
/// current run is at or above it — so the metric can only ratchet UP.
///
/// Every VI is summarized ONCE in a worker isolate ([corpusParallel]) and the
/// tests assert on the aggregate — there is no sampling tier, the heavy per-VI
/// work (decode + heap walk + model build) is just parallelized across cores.
const _heapTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

/// Per-VI coverage summary. Sendable across isolates (primitives + a small
/// `Map<int,int>` kind histogram + nullable failure strings).
class _Cov {
  /// parseVi/decodeSections/walk threw on a real VI.
  final String? totalityFail;

  /// A framed span ran past the section body.
  final String? walkFail;

  /// Heap-byte coverage numerator/denominators (framed and semantic over body).
  final int framed, body, semantic;

  /// Decoder-presence sentinels (a count drop signals a silently dropped decoder).
  final int propertyNames, helpStrings, controlF64;

  /// BD object-kind histogram for this VI.
  final Map<int, int> kinds;

  /// Structural node-fallback census.
  final int fallbackNodes, drawableUnknown;
  const _Cov({
    required this.totalityFail,
    required this.walkFail,
    required this.framed,
    required this.body,
    required this.semantic,
    required this.propertyNames,
    required this.helpStrings,
    required this.controlF64,
    required this.kinds,
    required this.fallbackNodes,
    required this.drawableUnknown,
  });
}

_Cov _covSumm(Uint8List bytes, String path) {
  var framed = 0, body = 0, semantic = 0;
  var propertyNames = 0, helpStrings = 0, controlF64 = 0;
  String? walkFail;
  String? totalityFail;

  try {
    parseVi(bytes);
    for (final s in decodeSections(bytes)) {
      if (!_heapTags.contains(s.tag) || s.bytes.length < 6) continue;
      final w = walkHeapBody(s.bytes);
      framed += w.coveredBytes;
      body += w.bodyBytes;
      for (final span in w.spans) {
        if (span.offset + span.length > s.bytes.length) {
          walkFail ??= 'OOB span in $path/${s.tag}';
        }
        if (heapDecodeTier(s.bytes, span.offset, span.lead, s.tag) == HeapDecodeTier.semantic) {
          semantic += span.length;
        }
        final a = decodeHeapAttr(s.bytes, span.offset);
        if (a == null) continue;
        if (a.attribute == HeapAttribute.propertyName) propertyNames++;
        if (a.attribute == HeapAttribute.helpDescription && a.asString != null && a.asString!.isNotEmpty) {
          helpStrings++;
        }
        if ((a.attribute == HeapAttribute.foregroundColor || a.attribute == HeapAttribute.foregroundColorB) &&
            a.width == HeapAttrWidth.f64) {
          controlF64++;
        }
      }
    }
  } catch (e) {
    if (!isNonRsrcFixture(path)) totalityFail = '$path: $e';
  }

  final kinds = <int, int>{};
  var fallbackNodes = 0, drawableUnknown = 0;
  try {
    final vi = buildViModel(bytes);
    for (final o in vi.blockDiagrams.expand((x) => x.objects)) {
      kinds[o.kind] = (kinds[o.kind] ?? 0) + 1;
      final b = o.absBounds;
      if (b == null || b.width <= 1 || b.height <= 1) continue;
      if (o.category == ViObjectKind.node && o.objectClass == HeapObjectClass.unknown) fallbackNodes++;
      if (o.category == ViObjectKind.unknown) drawableUnknown++;
    }
  } catch (_) {}

  return _Cov(
    totalityFail: totalityFail,
    walkFail: walkFail,
    framed: framed,
    body: body,
    semantic: semantic,
    propertyNames: propertyNames,
    helpStrings: helpStrings,
    controlF64: controlF64,
    kinds: kinds,
    fallbackNodes: fallbackNodes,
    drawableUnknown: drawableUnknown,
  );
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('corpus coverage (skipped: corpus not fetched — run tool/fetch_corpus.dart)', () {}, skip: true);
    return;
  }
  late final List<_Cov> C;
  setUpAll(() async {
    C = await corpusParallel(all, _covSumm);
  });

  test('every corpus VI parses, decodes, and walks without throwing (totality)', () {
    final fails = C.map((c) => c.totalityFail).whereType<String>().toList();
    final oob = C.map((c) => c.walkFail).whereType<String>().toList();
    expect(fails, isEmpty, reason: 'VIs failed to parse/decode/walk: ${fails.take(8).toList()}');
    expect(oob, isEmpty, reason: 'framed heap spans ran past the section body: ${oob.take(8).toList()}');
    expect(C.fold<int>(0, (a, c) => a + c.propertyNames), greaterThan(0), reason: 'propertyName (0x31) decode dropped');
    expect(C.fold<int>(0, (a, c) => a + c.helpStrings), greaterThan(0), reason: 'helpDescription (0x6c) string decode dropped');
    expect(C.fold<int>(0, (a, c) => a + c.controlF64), greaterThan(0), reason: '0x20/0x21 control-min/max f64 decode dropped');
  });

  test('"% deliberately parsed" AND "% semantically decoded" hold at or above baseline', () {
    final framed = C.fold<int>(0, (a, c) => a + c.framed);
    final body = C.fold<int>(0, (a, c) => a + c.body);
    final semantic = C.fold<int>(0, (a, c) => a + c.semantic);
    expect(body, greaterThan(0));

    final baselineFile = corpusBaselineFile();
    final base = baselineFile.existsSync()
        ? (jsonDecode(baselineFile.readAsStringSync()) as Map)['corpus'] as Map
        : const <String, Object?>{};
    num floor(String k) => (base[k] as num?) ?? 0.0;

    final framedPct = framed / body;
    expect(framedPct, greaterThanOrEqualTo(floor('deliberatelyParsed') - 0.001),
        reason: 'deliberately-parsed regressed to ${(framedPct * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor('deliberatelyParsed') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.');

    final semanticPct = semantic / body;
    expect(semanticPct, greaterThanOrEqualTo(floor('semanticallyDecoded') - 0.001),
        reason: 'semantically-decoded regressed to ${(semanticPct * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor('semanticallyDecoded') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.');
  });

  test('catalogued BD object kinds hold their full-corpus counts (anti-rot)', () {
    const expected = <int, int>{
      0x2f: 47539, 0x31: 33230, 0x63: 15293, 0x8c: 7407, 0x3a: 3746, 0xd6: 2437,
      0x32: 2649, 0xc5: 1522, 0x104: 2377, 0x44: 3535, 0x3e: 2038, 0x34: 1741, 0xa9: 2621,
      0x2c: 15598, 0x20: 5299, 0x21: 1677, 0x16: 42330, 0x95: 17228, 0x177: 17285,
      0x93: 1566, 0x172: 1411, 0x6c: 1112, 0x36: 1086, 0xcd: 1224, 0x14d: 904,
      0x55: 2341, 0x153: 1466, 0x4e: 977,
      0x6a: 981, 0xbd: 645, 0x114: 440, 0xb6: 533, 0xca: 565, 0x29: 483, 0x10c: 868, 0xc2: 690,
      0xd5: 399, 0x121: 849, 0xb9: 389, 0x48: 315, 0xeb: 226, 0x103: 217, 0x14a: 380,
    };
    final counts = {for (final k in expected.keys) k: 0};
    for (final c in C) {
      c.kinds.forEach((k, v) {
        if (counts.containsKey(k)) counts[k] = counts[k]! + v;
      });
    }
    expected.forEach((kind, exp) {
      expect(counts[kind]!, inInclusiveRange((exp * 0.8).floor(), (exp * 1.2).ceil()),
          reason: 'BD kind 0x${kind.toRadixString(16)} count ${counts[kind]} is >20% off the pinned $exp '
              '— update the catalog doc + this pin if the corpus/decode legitimately changed.');
    });
  });

  test('structural node-fallback keeps classifying the BD node tail (anti-regression)', () {
    final fallbackNodes = C.fold<int>(0, (a, c) => a + c.fallbackNodes);
    final drawableUnknown = C.fold<int>(0, (a, c) => a + c.drawableUnknown);
    expect(fallbackNodes, inInclusiveRange(1500, 2600),
        reason: 'node-fallback output ($fallbackNodes) drifted — the gate (parent 0x1b + 0x15 child '
            '+ no 0x68 + size cap) may have broken; the tail would revert to unknown boxes.');
    expect(drawableUnknown, lessThan(1600),
        reason: 'still-unknown drawable BD objects ($drawableUnknown) exceeded the ceiling — '
            'a new uncatalogued kind likely appeared; probe and classify it.');
  });
}
