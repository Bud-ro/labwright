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
/// The measured sections and the per-section tier arithmetic are shared with
/// the coverage tool ([kHeapSectionTags] / [measureHeapTiers]) so the ratchet
/// and the baseline generator cannot drift.

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

  /// partRole (0xDF) correlation sentinels: occurrences of exemplar values and
  /// how many sit in their evidence-dominant enclosing kind (see
  /// [HeapAttribute.partRole]).
  final int part16, part16InLabel, part66, part66InConnector, part8002, part8002InNumeric;

  /// Raw-tag upgrade sentinels: the corpus correlations behind the inferred
  /// meanings, re-measured on every run (see the [HeapAttribute] evidence notes).
  final int objFlagsTotal, objFlagsFirst; // 0x0CB: position-0-in-object invariant
  final int masterTotal, masterSiblingHit; // 0x0AF: sibling part carries partRole == value
  final int sigTotal, sigInSignal; // 0x1E7/0x09F: enclosing class 0x17 = signal
  final int tllTotal, tllEqChild; // 0x158: value == direct child-object count
  final int ddoTotal, ddoCrossResolved; // 14 53: uid resolves in the sibling heap
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
    required this.part16,
    required this.part16InLabel,
    required this.part66,
    required this.part66InConnector,
    required this.part8002,
    required this.part8002InNumeric,
    required this.objFlagsTotal,
    required this.objFlagsFirst,
    required this.masterTotal,
    required this.masterSiblingHit,
    required this.sigTotal,
    required this.sigInSignal,
    required this.tllTotal,
    required this.tllEqChild,
    required this.ddoTotal,
    required this.ddoCrossResolved,
  });
}

/// Per-object scratch for the raw-tag sentinels: enclosing kind, record
/// position, child count, and the partRole/masterPart values seen.
class _SentNode {
  _SentNode(this.kind, this.parent);
  final int kind;
  final _SentNode? parent;
  int records = 0, childCount = 0;
  List<int>? dfValues;
  List<int>? afValues;
  List<int>? tllValues;
}

_Cov _covSumm(Uint8List bytes, String path) {
  var framed = 0, body = 0, semantic = 0;
  var propertyNames = 0, helpStrings = 0, controlF64 = 0;
  var part16 = 0, part16InLabel = 0, part66 = 0, part66InConnector = 0, part8002 = 0, part8002InNumeric = 0;
  var objFlagsTotal = 0, objFlagsFirst = 0, masterTotal = 0, masterSiblingHit = 0;
  var sigTotal = 0, sigInSignal = 0, tllTotal = 0, tllEqChild = 0, ddoTotal = 0, ddoCrossResolved = 0;
  final oidsBySec = <String, Set<int>>{};
  final ddoPending = <(String, int)>[];
  String? walkFail;
  String? totalityFail;

  try {
    parseVi(bytes);
    for (final s in decodeSections(bytes)) {
      if (!kHeapSectionTags.contains(s.tag) || s.bytes.length < 6) continue;
      final tiers = measureHeapTiers(s.bytes, s.tag);
      framed += tiers.walk.coveredBytes;
      body += tiers.walk.bodyBytes;
      semantic += tiers.semanticBytes;
      for (final span in tiers.walk.spans) {
        if (span.offset + span.length > s.bytes.length) {
          walkFail ??= 'OOB span in $path/${s.tag}';
        }
        final a = decodeHeapAttr(s.bytes, span.offset);
        if (a == null) continue;
        if (a.attribute == HeapAttribute.propItemName) propertyNames++;
        if (a.attribute == HeapAttribute.constValue && (a.asString?.isNotEmpty ?? false)) {
          helpStrings++;
        }
        if ((a.attribute == HeapAttribute.stdNumMin || a.attribute == HeapAttribute.stdNumMax) &&
            a.width == HeapAttrWidth.f64) {
          controlF64++;
        }
      }
      // Correlation sentinels behind the inferred raw-tag meanings (partRole
      // enclosing kinds, objFlags position-0, masterPart sibling parts, the
      // signal chain scope, termListLength == child count, ddoRef cross-heap
      // resolution), re-measured on every run via the shared object-tree walk
      // so a meaning cannot silently rot.
      final nodes = <_SentNode>[];
      final oids = oidsBySec[s.tag] ??= <int>{};
      walkHeapObjects<_SentNode>(
        s.bytes,
        onObjectOpen: (span, kind, oid, parent) {
          final n = _SentNode(kind, parent);
          nodes.add(n);
          parent?.childCount++;
          oids.add(oid);
          return n;
        },
        onRecord: (span, node) {
          if (node == null || span.length < 2) return;
          final lead = s.bytes[span.offset];
          final idByte = s.bytes[span.offset + 1];
          node.records++;
          if (lead == 0x14 && idByte == 0x53 && span.length == 6 && s.bytes[span.offset + 3] == 0xfd) {
            final ref = decodeHeapRef(s.bytes, span.offset);
            if (ref != null) {
              ddoTotal++;
              ddoPending.add((s.tag, ref.targetOid));
            }
            return;
          }
          // Cheap pre-filter: every attribute form carries the tag low byte at
          // offset+1, so other bytes can never decode to the probed tags.
          if (!const {0xdf, 0xcb, 0xaf, 0xe7, 0x9f, 0x58}.contains(idByte)) return;
          final a = decodeHeapAttr(s.bytes, span.offset);
          if (a == null) return;
          switch (a.attribute) {
            case HeapAttribute.partRole:
              (node.dfValues ??= []).add(a.asInt ?? -1);
              switch (a.asInt) {
                case 16:
                  part16++;
                  if (node.kind == 0x0a) part16InLabel++;
                case 66:
                  part66++;
                  if (node.kind == 0x68) part66InConnector++;
                case 8002:
                  part8002++;
                  if (node.kind == 0x50) part8002InNumeric++;
              }
            case HeapAttribute.objFlags:
              objFlagsTotal++;
              if (node.records == 1) objFlagsFirst++;
            case HeapAttribute.masterPart:
              if (a.asInt != null) (node.afValues ??= []).add(a.asInt!);
            case HeapAttribute.compressedWireTable || HeapAttribute.lastSignalKind:
              sigTotal++;
              if (node.kind == 0x17) sigInSignal++;
            case HeapAttribute.termListLength:
              if (a.asInt != null) (node.tllValues ??= []).add(a.asInt!);
            default:
              break;
          }
        },
      );
      final childrenByParent = <_SentNode, List<_SentNode>>{};
      for (final n in nodes) {
        if (n.parent != null) (childrenByParent[n.parent!] ??= []).add(n);
      }
      for (final n in nodes) {
        for (final v in n.afValues ?? const <int>[]) {
          masterTotal++;
          final siblings = n.parent == null ? const <_SentNode>[] : (childrenByParent[n.parent!] ?? const []);
          if (siblings.any((sib) => sib.dfValues?.contains(v) ?? false)) masterSiblingHit++;
        }
        for (final v in n.tllValues ?? const <int>[]) {
          tllTotal++;
          if (v == n.childCount) tllEqChild++;
        }
      }
    }
    for (final (tag, uid) in ddoPending) {
      var cross = false;
      oidsBySec.forEach((t, ids) {
        if (t != tag && ids.contains(uid)) cross = true;
      });
      if (cross) ddoCrossResolved++;
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
    part16: part16,
    part16InLabel: part16InLabel,
    part66: part66,
    part66InConnector: part66InConnector,
    part8002: part8002,
    part8002InNumeric: part8002InNumeric,
    objFlagsTotal: objFlagsTotal,
    objFlagsFirst: objFlagsFirst,
    masterTotal: masterTotal,
    masterSiblingHit: masterSiblingHit,
    sigTotal: sigTotal,
    sigInSignal: sigInSignal,
    tllTotal: tllTotal,
    tllEqChild: tllEqChild,
    ddoTotal: ddoTotal,
    ddoCrossResolved: ddoCrossResolved,
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
    expect(
      C.fold<int>(0, (a, c) => a + c.helpStrings),
      greaterThan(0),
      reason: 'helpDescription (0x6c) string decode dropped',
    );
    expect(
      C.fold<int>(0, (a, c) => a + c.controlF64),
      greaterThan(0),
      reason: '0x20/0x21 control-min/max f64 decode dropped',
    );
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
    expect(
      framedPct,
      greaterThanOrEqualTo(floor('deliberatelyParsed') - 0.001),
      reason:
          'deliberately-parsed regressed to ${(framedPct * 100).toStringAsFixed(1)}% '
          '(baseline ${(floor('deliberatelyParsed') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.',
    );

    final semanticPct = semantic / body;
    expect(
      semanticPct,
      greaterThanOrEqualTo(floor('semanticallyDecoded') - 0.001),
      reason:
          'semantically-decoded regressed to ${(semanticPct * 100).toStringAsFixed(1)}% '
          '(baseline ${(floor('semanticallyDecoded') * 100).toStringAsFixed(1)}%). Re-run tool/coverage.dart only if this is a real improvement.',
    );
  });

  // Pin the corpus correlations behind the partRole (0xDF) inferred upgrade.
  // The name rests on the value->enclosing-kind evidence in
  // [HeapAttribute.partRole]; re-assert its exemplar cells over the whole corpus
  // so the inferred meaning fails loudly if the walker, the decode, or a corpus
  // refresh breaks the correlation.
  test('partRole (0xDF) exemplar value->enclosing-kind correlations hold corpus-wide', () {
    final part16 = C.fold<int>(0, (a, c) => a + c.part16);
    final part16InLabel = C.fold<int>(0, (a, c) => a + c.part16InLabel);
    final part66 = C.fold<int>(0, (a, c) => a + c.part66);
    final part66InConnector = C.fold<int>(0, (a, c) => a + c.part66InConnector);
    final part8002 = C.fold<int>(0, (a, c) => a + c.part8002);
    final part8002InNumeric = C.fold<int>(0, (a, c) => a + c.part8002InNumeric);

    expect(part16, greaterThan(100000), reason: 'partRole value 16 population collapsed (evidence: 335,898)');
    expect(part66, greaterThan(100000), reason: 'partRole value 66 population collapsed (evidence: 280,747)');
    expect(part8002, greaterThan(5000), reason: 'partRole value 8002 population collapsed (evidence: 12,817)');
    expect(
      part16InLabel / part16,
      greaterThanOrEqualTo(0.999),
      reason: 'partRole 16 must sit in label objects (kind 0x0A) at >=99.9% (evidence: 335,878/335,898)',
    );
    expect(
      part66InConnector / part66,
      greaterThanOrEqualTo(0.999),
      reason: 'partRole 66 must sit in connector terminals (kind 0x68) at >=99.9% (evidence: 280,711/280,747)',
    );
    expect(
      part8002InNumeric / part8002,
      greaterThanOrEqualTo(0.995),
      reason: 'partRole 8002 must sit in numeric controls (kind 0x50) at >=99.5% (evidence: 12,801/12,817)',
    );
  });

  // Pin the corpus correlations behind the raw-tag-id upgrades (objFlags,
  // masterPart, the signal chain, termListLength, ddoRef). Each floor sits just
  // under its measured full-corpus figure so the inferred meaning fails loudly
  // if the decode, the walker, or a corpus refresh breaks the correlation.
  test('raw-tag upgrade correlations hold corpus-wide (objFlags/masterPart/signal/termList/ddoRef)', () {
    int sum(int Function(_Cov c) f) => C.fold<int>(0, (a, c) => a + f(c));
    final objTotal = sum((c) => c.objFlagsTotal), objFirst = sum((c) => c.objFlagsFirst);
    expect(objTotal, greaterThan(3500000), reason: 'objFlags population collapsed (evidence: 3,745,810)');
    expect(
      objFirst / objTotal,
      greaterThanOrEqualTo(0.999),
      reason: 'objFlags must be the FIRST record of its object scope (evidence: 99.99%)',
    );
    final masterTotal = sum((c) => c.masterTotal), masterHit = sum((c) => c.masterSiblingHit);
    expect(masterTotal, greaterThan(800000), reason: 'masterPart population collapsed (evidence: 918,340)');
    expect(
      masterHit / masterTotal,
      greaterThanOrEqualTo(0.96),
      reason: 'a sibling part must carry partRole == masterPart value (evidence: 97.29%)',
    );
    final sigTotal = sum((c) => c.sigTotal), sigIn = sum((c) => c.sigInSignal);
    expect(sigTotal, greaterThan(700000), reason: 'signal-chain population collapsed (evidence: 854,486)');
    expect(
      sigIn / sigTotal,
      greaterThanOrEqualTo(0.999),
      reason: 'compressedWireTable/lastSignalKind must sit in signal objects, class 0x17 (evidence: ~100%)',
    );
    final tllTotal = sum((c) => c.tllTotal), tllEq = sum((c) => c.tllEqChild);
    expect(tllTotal, greaterThan(30000), reason: 'termListLength population collapsed (evidence: 41,660)');
    expect(
      tllEq / tllTotal,
      greaterThanOrEqualTo(0.96),
      reason: 'termListLength must equal the direct child-object count (evidence: 97.56%)',
    );
    final ddoTotal = sum((c) => c.ddoTotal), ddoCross = sum((c) => c.ddoCrossResolved);
    expect(ddoTotal, greaterThan(1500), reason: 'ddoRef population collapsed (evidence: 2,048)');
    expect(
      ddoCross / ddoTotal,
      greaterThanOrEqualTo(0.99),
      reason: 'ddoRef uids must resolve in the sibling heap (evidence: 2,048/2,048)',
    );
  });

  // Pin the STRUCTURAL NODE-FALLBACK output (category==node while objectClass is
  // uncatalogued) so the headline render improvement can't silently regress to 0
  // if the 0x1b-container code or the gate conditions drift. Also cap the total
  // still-unknown drawable tail so a NEW uncatalogued bucket surfaces loudly.
  test('structural node-fallback keeps classifying the BD node tail (anti-regression)', () {
    final fallbackNodes = C.fold<int>(0, (a, c) => a + c.fallbackNodes);
    final drawableUnknown = C.fold<int>(0, (a, c) => a + c.drawableUnknown);
    expect(
      fallbackNodes,
      inInclusiveRange(1500, 2600),
      reason:
          'node-fallback output ($fallbackNodes) drifted — the gate (parent 0x1b + 0x15 child '
          '+ no 0x68 + size cap) may have broken; the tail would revert to unknown boxes.',
    );
    expect(
      drawableUnknown,
      lessThan(1600),
      reason:
          'still-unknown drawable BD objects ($drawableUnknown) exceeded the ceiling — '
          'a new uncatalogued kind likely appeared; probe and classify it.',
    );
  });
}
