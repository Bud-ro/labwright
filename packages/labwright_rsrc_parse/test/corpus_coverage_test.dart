@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

typedef _Cov = ({
  String? totalityFail,
  String? walkFail,
  int parseOk,
  int decodeOk,
  int blockInstances,
  int blocksIdentified,
  int blockBytes,
  int blockBytesDecoded,
  int heaps,
  int fullHeaps,
  int framed,
  int body,
  int semantic,
  int valueKind,
  int propertyNames,
  int helpStrings,
  int controlF64,
  int fallbackNodes,
  int drawableUnknown,
  Map<String, int> sent,
});

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
  var framed = 0, body = 0, semantic = 0, valueKind = 0;
  var parseOk = 0, decodeOk = 0, heaps = 0, fullHeaps = 0;
  var blockInstances = 0, blocksIdentified = 0, blockBytes = 0, blockBytesDecoded = 0;
  var propertyNames = 0, helpStrings = 0, controlF64 = 0;
  final sent = <String, int>{};
  void n(String k) => sent[k] = (sent[k] ?? 0) + 1;
  final oidsBySec = <String, Set<int>>{};
  final ddoPending = <(String, int)>[];
  String? walkFail;
  String? totalityFail;

  try {
    parseVi(bytes);
    parseOk = 1;
    final dsecs = decodeSections(bytes);
    decodeOk = 1;
    for (final s in dsecs) {
      blockInstances++;
      if (isCataloguedTag(s.tag)) blocksIdentified++;
      blockBytes += s.bytes.length;
      if (blockInfo(s.tag).isDecoded) blockBytesDecoded += s.bytes.length;
      if (!kHeapSectionTags.contains(s.tag) || s.bytes.length < 6) continue;
      final tiers = measureHeapTiers(s.bytes, s.tag);
      heaps++;
      if (tiers.walk.complete) fullHeaps++;
      framed += tiers.walk.coveredBytes;
      body += tiers.walk.bodyBytes;
      semantic += tiers.semanticBytes;
      valueKind += tiers.valueKindBytes;
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
    parseOk: parseOk,
    decodeOk: decodeOk,
    blockInstances: blockInstances,
    blocksIdentified: blocksIdentified,
    blockBytes: blockBytes,
    blockBytesDecoded: blockBytesDecoded,
    heaps: heaps,
    fullHeaps: fullHeaps,
    framed: framed,
    body: body,
    semantic: semantic,
    valueKind: valueKind,
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
  });

  test('coverage axes, decode sentinels, and raw-tag correlations match the committed snapshot', () {
    int sum(int Function(_Cov) f) => C.fold(0, (a, c) => a + f(c));
    final sentKeys = <String>{for (final c in C) ...c.sent.keys};
    expectCorpusSnapshot('coverage', {
      'vis': C.length,
      'parseOk': sum((c) => c.parseOk),
      'decodeOk': sum((c) => c.decodeOk),
      'blockInstances': sum((c) => c.blockInstances),
      'blocksIdentified': sum((c) => c.blocksIdentified),
      'blockBytes': sum((c) => c.blockBytes),
      'blockBytesDecoded': sum((c) => c.blockBytesDecoded),
      'heaps': sum((c) => c.heaps),
      'heapsComplete': sum((c) => c.fullHeaps),
      'heapFramedBytes': sum((c) => c.framed),
      'heapBodyBytes': sum((c) => c.body),
      'heapSemanticBytes': sum((c) => c.semantic),
      'heapValueKindBytes': sum((c) => c.valueKind),
      'propertyNames': sum((c) => c.propertyNames),
      'helpStrings': sum((c) => c.helpStrings),
      'controlF64': sum((c) => c.controlF64),
      'fallbackNodes': sum((c) => c.fallbackNodes),
      'drawableUnknown': sum((c) => c.drawableUnknown),
      for (final k in sentKeys) 'sent:$k': S(k),
    });
  });
}
