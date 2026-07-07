import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Round-3 verification for the residual value-kind tags:
///
///   0x159 / 0x15A — candidate refListLength / hGrowNodeListLength (the tags
///     adjacent to the verified 0x158 termListLength): scope, values, and the
///     structural identities value == `14 19` ref count / value == direct
///     child count.
///   0x25E (candidate MinButSize) / 0x12A (candidate termHotPoint) — scope +
///     packed (s16,s16) plausibility.
///   0x27E (candidate TunnelType), 0x263 (candidate ParForNumStaticWorkers),
///   0x119, 0x1B2, 0x1B8, 0x0E0, 0x0E8, 0x144 — scope + value shape.
///
/// Run: `dart run tool/probe_tag_verify3.dart [corpusRoot=<pkg>/corpus/vi]`

const Set<int> kTargets = {0x159, 0x15a, 0x25e, 0x12a, 0x27e, 0x263, 0x119, 0x1b2, 0x1b8, 0x0e0, 0x0e8, 0x144};

class Hist {
  final Map<int, int> counts = {};
  int total = 0;
  void add(int v) {
    total++;
    if (counts.length < 4096 || counts.containsKey(v)) counts[v] = (counts[v] ?? 0) + 1;
  }

  void merge(Hist o) {
    total += o.total;
    o.counts.forEach((k, n) {
      if (counts.length < 4096 || counts.containsKey(k)) counts[k] = (counts[k] ?? 0) + n;
    });
  }

  List<MapEntry<int, int>> top(int n) => (counts.entries.toList()..sort((a, b) => b.value - a.value)).take(n).toList();
}

class _Node {
  _Node(this.kind);
  final int kind;
  int childCount = 0, ref19Count = 0;
  List<int>? v159, v15a;
}

class _Agg {
  final Map<int, Hist> classes = {};
  final Map<int, Hist> values = {};
  int t159 = 0, t159EqRef = 0, t159EqChild = 0;
  int t15a = 0, t15aEqRef = 0, t15aEqChild = 0;
  int pt25e = 0, pt25eOk = 0, pt12a = 0, pt12aOk = 0;

  void merge(_Agg o) {
    o.classes.forEach((k, h) => (classes[k] ??= Hist()).merge(h));
    o.values.forEach((k, h) => (values[k] ??= Hist()).merge(h));
    t159 += o.t159;
    t159EqRef += o.t159EqRef;
    t159EqChild += o.t159EqChild;
    t15a += o.t15a;
    t15aEqRef += o.t15aEqRef;
    t15aEqChild += o.t15aEqChild;
    pt25e += o.pt25e;
    pt25eOk += o.pt25eOk;
    pt12a += o.pt12a;
    pt12aOk += o.pt12aOk;
  }
}

void _probeVi(Uint8List bytes, _Agg agg) {
  final List<DecodedSection> secs;
  try {
    secs = decodeSections(bytes);
  } catch (_) {
    return;
  }
  for (final sec in secs) {
    if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
    final body = sec.bytes;
    final nodes = <_Node>[];
    walkHeapObjects<_Node>(
      body,
      onObjectOpen: (span, kind, oid, parent) {
        final n = _Node(kind);
        nodes.add(n);
        parent?.childCount++;
        return n;
      },
      onRecord: (span, node) {
        final offset = span.offset;
        final lead = span.lead;
        if (offset + 2 > body.length) return;
        final raw = ((lead & 3) << 8) | body[offset + 1];
        if (lead == 0x14 && raw == 0x019 && node != null) node.ref19Count++;
        if (!kTargets.contains(raw)) return;
        final a = decodeHeapAttr(body, offset);
        final v = a?.asInt;
        if (a == null || v == null) return;
        (agg.classes[raw] ??= Hist()).add(node?.kind ?? -1);
        (agg.values[raw] ??= Hist()).add(v);
        if (raw == 0x159 && node != null) (node.v159 ??= []).add(v);
        if (raw == 0x15a && node != null) (node.v15a ??= []).add(v);
        if (raw == 0x25e && a.width == HeapAttrWidth.rgb) {
          agg.pt25e++;
          final h = (v >> 16).toSigned(16), w = (v & 0xffff).toSigned(16);
          if (h >= 0 && w >= 0 && h < 4096 && w < 4096) agg.pt25eOk++;
        }
        if (raw == 0x12a && a.width == HeapAttrWidth.rgb) {
          agg.pt12a++;
          final y = (v >> 16).toSigned(16), x = (v & 0xffff).toSigned(16);
          if (y.abs() < 4096 && x.abs() < 4096) agg.pt12aOk++;
        }
      },
    );
    for (final n in nodes) {
      for (final v in n.v159 ?? const <int>[]) {
        agg.t159++;
        if (v == n.ref19Count) agg.t159EqRef++;
        if (v == n.childCount) agg.t159EqChild++;
      }
      for (final v in n.v15a ?? const <int>[]) {
        agg.t15a++;
        if (v == n.ref19Count) agg.t15aEqRef++;
        if (v == n.childCount) agg.t15aEqChild++;
      }
    }
  }
}

String _pct(int a, int b) => b == 0 ? '-' : (100 * a / b).toStringAsFixed(2);

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final files = listCorpusVis(Directory(root));
  stdout.writeln('corpus: ${files.length} VIs under $root');
  final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(workers, (_) => <String>[]);
  for (var i = 0; i < files.length; i++) {
    chunks[i % workers].add(files[i].path);
  }
  final aggs = await Future.wait(
    chunks.map(
      (chunk) => Isolate.run(() {
        final agg = _Agg();
        for (final p in chunk) {
          _probeVi(File(p).readAsBytesSync(), agg);
        }
        return agg;
      }),
    ),
  );
  final agg = _Agg();
  for (final a in aggs) {
    agg.merge(a);
  }

  for (final raw in kTargets.toList()..sort()) {
    final ch = agg.classes[raw], vh = agg.values[raw];
    if (ch == null || vh == null) {
      stdout.writeln('raw 0x${raw.toRadixString(16)}: no records');
      continue;
    }
    stdout.writeln(
      'raw 0x${raw.toRadixString(16)} n=${ch.total} '
      'classes ${ch.top(6).map((e) => '0x${e.key.toRadixString(16)}:${_pct(e.value, ch.total)}%').join(' ')} '
      '| values(distinct=${vh.counts.length}) ${vh.top(6).map((e) => '${e.key}:${_pct(e.value, vh.total)}%').join(' ')}',
    );
  }
  stdout.writeln(
    '0x159: n=${agg.t159} ==ref19Count=${agg.t159EqRef} (${_pct(agg.t159EqRef, agg.t159)}%) '
    '==childCount=${agg.t159EqChild} (${_pct(agg.t159EqChild, agg.t159)}%)',
  );
  stdout.writeln(
    '0x15A: n=${agg.t15a} ==ref19Count=${agg.t15aEqRef} (${_pct(agg.t15aEqRef, agg.t15a)}%) '
    '==childCount=${agg.t15aEqChild} (${_pct(agg.t15aEqChild, agg.t15a)}%)',
  );
  stdout.writeln('0x25E size-pair plausible: ${agg.pt25eOk}/${agg.pt25e} (${_pct(agg.pt25eOk, agg.pt25e)}%)');
  stdout.writeln('0x12A point plausible: ${agg.pt12aOk}/${agg.pt12a} (${_pct(agg.pt12aOk, agg.pt12a)}%)');
}
