@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Mechanical regression guard over the pinned corpus. The "% deliberately parsed" and
/// "% semantically decoded" floors come from corpus/baseline.json (written by tool/coverage.dart over
/// the WHOLE corpus) so the metric can only ratchet UP; the per-section tier arithmetic is shared with
/// the tool ([kHeapSectionTags]/[measureHeapTiers]) so ratchet and generator cannot drift. Each VI is
/// summarized ONCE in a worker isolate; tests assert on the aggregate.
typedef _Cov = ({
  String? totalityFail, // parseVi/decodeSections/walk threw on a real VI
  String? walkFail, // a framed span ran past the section body
  int framed,
  int body,
  int semantic,
  int propertyNames, // decoder-presence sentinels: a count drop = silently dropped decoder
  int helpStrings,
  int controlF64,
  int fallbackNodes,
  int drawableUnknown,
  Map<String, int> sent, // correlation sentinels behind the inferred raw-tag upgrades
});

/// Per-object scratch for the raw-tag sentinels.
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
  final sent = <String, int>{};
  void n(String k) => sent[k] = (sent[k] ?? 0) + 1;
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
        if (span.offset + span.length > s.bytes.length) walkFail ??= 'OOB span in $path/${s.tag}';
        final a = decodeHeapAttr(s.bytes, span.offset);
        if (a == null) continue;
        if (a.attribute == HeapAttribute.propItemName) propertyNames++;
        if (a.attribute == HeapAttribute.constValue && (a.asString?.isNotEmpty ?? false)) helpStrings++;
        if ((a.attribute == HeapAttribute.stdNumMin || a.attribute == HeapAttribute.stdNumMax) &&
            a.width == HeapAttrWidth.f64) {
          controlF64++;
        }
      }
      // Sentinels: partRole enclosing kinds, objFlags position-0, masterPart sibling parts, the
      // signal chain scope, termListLength == child count, ddoRef cross-heap resolution.
      final nodes = <_SentNode>[];
      final oids = oidsBySec[s.tag] ??= <int>{};
      walkHeapObjects<_SentNode>(
        s.bytes,
        onObjectOpen: (span, kind, oid, parent) {
          final node = _SentNode(kind, parent);
          nodes.add(node);
          parent?.childCount++;
          oids.add(oid);
          return node;
        },
        onRecord: (span, node) {
          if (node == null || span.length < 2) return;
          final lead = s.bytes[span.offset];
          final idByte = s.bytes[span.offset + 1];
          node.records++;
          if (lead == 0x14 && idByte == 0x53 && span.length == 6 && s.bytes[span.offset + 3] == 0xfd) {
            final ref = decodeHeapRef(s.bytes, span.offset);
            if (ref != null) {
              n('ddoTotal');
              ddoPending.add((s.tag, ref.targetOid));
            }
            return;
          }
          // Every attribute form carries the tag low byte at offset+1 — cheap pre-filter.
          if (!const {0xdf, 0xcb, 0xaf, 0xe7, 0x9f, 0x58}.contains(idByte)) return;
          final a = decodeHeapAttr(s.bytes, span.offset);
          if (a == null) return;
          switch (a.attribute) {
            case HeapAttribute.partRole:
              (node.dfValues ??= []).add(a.asInt ?? -1);
              switch (a.asInt) {
                case 16:
                  n('part16');
                  if (node.kind == 0x0a) n('part16InLabel');
                case 66:
                  n('part66');
                  if (node.kind == 0x68) n('part66InConnector');
                case 8002:
                  n('part8002');
                  if (node.kind == 0x50) n('part8002InNumeric');
              }
            case HeapAttribute.objFlags:
              n('objTotal');
              if (node.records == 1) n('objFirst');
            case HeapAttribute.masterPart:
              if (a.asInt != null) (node.afValues ??= []).add(a.asInt!);
            case HeapAttribute.compressedWireTable || HeapAttribute.lastSignalKind:
              n('sigTotal');
              if (node.kind == 0x17) n('sigInSignal');
            case HeapAttribute.termListLength:
              if (a.asInt != null) (node.tllValues ??= []).add(a.asInt!);
            default:
              break;
          }
        },
      );
      final childrenByParent = <_SentNode, List<_SentNode>>{};
      for (final node in nodes) {
        if (node.parent != null) (childrenByParent[node.parent!] ??= []).add(node);
      }
      for (final node in nodes) {
        for (final v in node.afValues ?? const <int>[]) {
          n('masterTotal');
          final siblings = node.parent == null ? const <_SentNode>[] : (childrenByParent[node.parent!] ?? const []);
          if (siblings.any((sib) => !identical(sib, node) && (sib.dfValues?.contains(v) ?? false))) {
            n('masterSiblingHit');
          }
        }
        for (final v in node.tllValues ?? const <int>[]) {
          n('tllTotal');
          if (v == node.childCount) n('tllEqChild');
        }
      }
    }
    for (final (tag, uid) in ddoPending) {
      var cross = false;
      oidsBySec.forEach((t, ids) {
        if (t != tag && ids.contains(uid)) cross = true;
      });
      if (cross) n('ddoCrossResolved');
    }
  } catch (e) {
    if (!isNonRsrcFixture(path)) totalityFail = '$path: $e';
  }

  var fallbackNodes = 0, drawableUnknown = 0;
  try {
    final vi = buildViModel(bytes);
    for (final o in vi.blockDiagrams.expand((x) => x.objects)) {
      final b = o.absBounds;
      if (b == null || b.width <= 1 || b.height <= 1) continue;
      if (o.category == ViObjectKind.node && o.objectClass == HeapObjectClass.unknown) fallbackNodes++;
      if (o.category == ViObjectKind.unknown) drawableUnknown++;
    }
  } catch (_) {}

  return (
    totalityFail: totalityFail,
    walkFail: walkFail,
    framed: framed,
    body: body,
    semantic: semantic,
    propertyNames: propertyNames,
    helpStrings: helpStrings,
    controlF64: controlF64,
    fallbackNodes: fallbackNodes,
    drawableUnknown: drawableUnknown,
    sent: sent,
  );
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('corpus coverage (skipped: corpus not fetched — run tool/fetch_corpus.dart)', () {}, skip: true);
    return;
  }
  late final List<_Cov> C;
  late final int Function(String) S;
  setUpAll(() async {
    C = await corpusParallel(all, _covSumm);
    S = (k) => C.fold(0, (a, c) => a + (c.sent[k] ?? 0));
  });

  test('every corpus VI parses, decodes, and walks without throwing (totality)', () {
    final fails = C.map((c) => c.totalityFail).whereType<String>().toList();
    final oob = C.map((c) => c.walkFail).whereType<String>().toList();
    expect(fails, isEmpty, reason: 'VIs failed to parse/decode/walk: ${fails.take(8).toList()}');
    expect(oob, isEmpty, reason: 'framed heap spans ran past the section body: ${oob.take(8).toList()}');
    expect(C.fold(0, (a, c) => a + c.propertyNames), greaterThan(0), reason: 'propertyName (0x31) decode dropped');
    expect(C.fold(0, (a, c) => a + c.helpStrings), greaterThan(0), reason: 'helpDescription (0x6c) decode dropped');
    expect(C.fold(0, (a, c) => a + c.controlF64), greaterThan(0), reason: '0x20/0x21 min/max f64 decode dropped');
  });

  test('"% deliberately parsed" AND "% semantically decoded" hold at or above baseline', () {
    final framed = C.fold(0, (a, c) => a + c.framed);
    final body = C.fold(0, (a, c) => a + c.body);
    final semantic = C.fold(0, (a, c) => a + c.semantic);
    expect(body, greaterThan(0));

    final baselineFile = corpusBaselineFile();
    final base = baselineFile.existsSync()
        ? (jsonDecode(baselineFile.readAsStringSync()) as Map)['corpus'] as Map
        : const <String, Object?>{};
    num floor(String k) => (base[k] as num?) ?? 0.0;

    for (final (label, pct, key) in [
      ('deliberately-parsed', framed / body, 'deliberatelyParsed'),
      ('semantically-decoded', semantic / body, 'semanticallyDecoded'),
    ]) {
      expect(
        pct,
        greaterThanOrEqualTo(floor(key) - 0.001),
        reason:
            '$label regressed to ${(pct * 100).toStringAsFixed(1)}% '
            '(baseline ${(floor(key) * 100).toStringAsFixed(1)}%). '
            'Re-run tool/coverage.dart only if this is a real improvement.',
      );
    }
  });

  test('partRole (0xDF) exemplar value->enclosing-kind correlations hold corpus-wide', () {
    expect(S('part16'), greaterThan(100000), reason: 'partRole value 16 population collapsed');
    expect(S('part66'), greaterThan(100000), reason: 'partRole value 66 population collapsed');
    expect(S('part8002'), greaterThan(5000), reason: 'partRole value 8002 population collapsed');
    expect(
      S('part16InLabel') / S('part16'),
      greaterThanOrEqualTo(0.999),
      reason: 'partRole 16 must sit in label objects (kind 0x0A) at >=99.9%',
    );
    expect(
      S('part66InConnector') / S('part66'),
      greaterThanOrEqualTo(0.999),
      reason: 'partRole 66 must sit in connector terminals (kind 0x68) at >=99.9%',
    );
    expect(
      S('part8002InNumeric') / S('part8002'),
      greaterThanOrEqualTo(0.995),
      reason: 'partRole 8002 must sit in numeric controls (kind 0x50) at >=99.5%',
    );
  });

  test('raw-tag upgrade correlations hold corpus-wide (objFlags/masterPart/signal/termList/ddoRef)', () {
    expect(S('objTotal'), greaterThan(3500000), reason: 'objFlags population collapsed');
    expect(
      S('objFirst') / S('objTotal'),
      greaterThanOrEqualTo(0.999),
      reason: 'objFlags must be the FIRST record of its object scope',
    );
    expect(S('masterTotal'), greaterThan(800000), reason: 'masterPart population collapsed');
    expect(
      S('masterSiblingHit') / S('masterTotal'),
      greaterThanOrEqualTo(0.96),
      reason: 'a DISTINCT sibling part must carry partRole == masterPart value',
    );
    expect(S('sigTotal'), greaterThan(700000), reason: 'signal-chain population collapsed');
    expect(
      S('sigInSignal') / S('sigTotal'),
      greaterThanOrEqualTo(0.999),
      reason: 'compressedWireTable/lastSignalKind must sit in signal objects (class 0x17)',
    );
    expect(S('tllTotal'), greaterThan(30000), reason: 'termListLength population collapsed');
    expect(
      S('tllEqChild') / S('tllTotal'),
      greaterThanOrEqualTo(0.96),
      reason: 'termListLength must equal the direct child-object count',
    );
    expect(S('ddoTotal'), greaterThan(1500), reason: 'ddoRef population collapsed');
    expect(
      S('ddoCrossResolved') / S('ddoTotal'),
      greaterThanOrEqualTo(0.99),
      reason: 'ddoRef uids must resolve in the sibling heap',
    );
  });

  test('structural node-fallback keeps classifying the BD node tail (anti-regression)', () {
    final fallbackNodes = C.fold(0, (a, c) => a + c.fallbackNodes);
    final drawableUnknown = C.fold(0, (a, c) => a + c.drawableUnknown);
    expect(
      fallbackNodes,
      inInclusiveRange(1500, 2600),
      reason:
          'node-fallback output drifted — the gate (parent 0x1b + 0x15 child + no 0x68 + size cap) '
          'may have broken; the tail would revert to unknown boxes.',
    );
    expect(
      drawableUnknown,
      lessThan(1600),
      reason: 'still-unknown drawable BD objects exceeded the ceiling — probe and classify the new kind.',
    );
  });
}
