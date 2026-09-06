import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Run: `dart run tool/probe_gap_census.dart [corpusRoot=<pkg>/corpus/vi]`

class CappedHist {
  final Map<int, int> counts = {};
  int overflow = 0;
  int total = 0;
  static const int cap = 4096;

  void add(int v, [int n = 1]) {
    total += n;
    final cur = counts[v];
    if (cur != null) {
      counts[v] = cur + n;
    } else if (counts.length < cap) {
      counts[v] = n;
    } else {
      overflow += n;
    }
  }

  void merge(CappedHist other) {
    other.counts.forEach(add);
    overflow += other.overflow;
    total += other.overflow;
  }

  List<MapEntry<int, int>> top(int n) {
    final entries = counts.entries.toList()..sort((a, b) => b.value - a.value);
    return entries.take(n).toList();
  }
}

class _Agg {
  final Map<String, int> tierKeyBytes = {};
  final Map<String, int> tierKeyCount = {};

  final Map<String, CappedHist> cbByPrevKey = {};
  final Map<String, CappedHist> cbByNextKey = {};
  final Map<int, CappedHist> cbByteHist = {};
  int cbU24 = 0, cbU24Lo16Zero = 0, cbU24Lo8Zero = 0;
  int cbU16 = 0, cbU8 = 0, cbRgb = 0;
  final Map<String, int> idMatch = {};
  int idTrialsBounds = 0, idTrialsCaption = 0, idTrialsPrevAttr = 0, idTrialsOid = 0;
  final CappedHist cbPosition = CappedHist();
  int monoParents = 0, monoNonDec = 0, monoStrictInc = 0, monoAllEqual = 0;
  int multiCbObjects = 0, multiCbNonDec = 0, multiCbAllEqual = 0;
  final Map<String, CappedHist> cbByVersion = {};
  final Map<int, CappedHist> cbByKindU24Hi = {};

  void bump(Map<String, int> m, String k, int n) => m[k] = (m[k] ?? 0) + n;

  void merge(_Agg o) {
    o.tierKeyBytes.forEach((k, v) => bump(tierKeyBytes, k, v));
    o.tierKeyCount.forEach((k, v) => bump(tierKeyCount, k, v));
    void mh(Map<String, CappedHist> into, Map<String, CappedHist> from) =>
        from.forEach((k, h) => (into[k] ??= CappedHist()).merge(h));
    void mhi(Map<int, CappedHist> into, Map<int, CappedHist> from) =>
        from.forEach((k, h) => (into[k] ??= CappedHist()).merge(h));
    mh(cbByPrevKey, o.cbByPrevKey);
    mh(cbByNextKey, o.cbByNextKey);
    mhi(cbByteHist, o.cbByteHist);
    mh(cbByVersion, o.cbByVersion);
    mhi(cbByKindU24Hi, o.cbByKindU24Hi);
    cbU24 += o.cbU24;
    cbU24Lo16Zero += o.cbU24Lo16Zero;
    cbU24Lo8Zero += o.cbU24Lo8Zero;
    cbU16 += o.cbU16;
    cbU8 += o.cbU8;
    cbRgb += o.cbRgb;
    o.idMatch.forEach((k, v) => bump(idMatch, k, v));
    idTrialsBounds += o.idTrialsBounds;
    idTrialsCaption += o.idTrialsCaption;
    idTrialsPrevAttr += o.idTrialsPrevAttr;
    idTrialsOid += o.idTrialsOid;
    cbPosition.merge(o.cbPosition);
    monoParents += o.monoParents;
    monoNonDec += o.monoNonDec;
    monoStrictInc += o.monoStrictInc;
    monoAllEqual += o.monoAllEqual;
    multiCbObjects += o.multiCbObjects;
    multiCbNonDec += o.multiCbNonDec;
    multiCbAllEqual += o.multiCbAllEqual;
  }
}

class _Node {
  _Node(this.kind, this.oid, this.parent);
  final int kind, oid;
  final _Node? parent;
  final List<_Node> children = [];
  HeapRect? bounds;
  int? captionLen;
  List<(int, int, int)>? cb;
  int recordIndex = 0;
}

class _Ev {
  _Ev(this.offset, this.length, this.lead, this.node, this.key);
  final int offset, length, lead;
  final _Node? node;
  final String key;
}

String _keyAt(Uint8List body, int offset, int lead) {
  if (heapObjectHeaderAt(body, offset) != null) return 'hdr';
  if (kHeapGroupCloseLeads.contains(lead)) return 'close';
  if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) {
    return 'grp';
  }
  if (lead == 0x14) {
    return offset + 2 <= body.length ? 'ref:${body[offset + 1].toRadixString(16)}' : 'ref:?';
  }
  if (lead == kHeapRecordPrefix) {
    return offset + 2 <= body.length ? 'C4:${body[offset + 1].toRadixString(16)}' : 'C4:?';
  }
  final lo = lead & 0xf, hi = lead >> 4;
  if (lo == 4 || lo == 5 || lo == 6) {
    final id = offset + 2 <= body.length ? body[offset + 1].toRadixString(16) : '?';
    final w = switch (hi) {
      0x2 => 'u8',
      0x4 => 'u16',
      0x6 => 'u24',
      0x8 => 'rgb',
      0xe => 'flag',
      0xc => 'cx',
      _ => 'w$hi',
    };
    return 'attr:$id:$w';
  }
  if (hi == 0 || hi == 1) {
    final sub = offset + 2 <= body.length ? body[offset + 1].toRadixString(16) : '?';
    return 'tok:${lead.toRadixString(16)}.$sub';
  }
  return 'L:${lead.toRadixString(16)}';
}

void _probeVi(Uint8List bytes, _Agg agg) {
  final List<DecodedSection> secs;
  String version;
  try {
    secs = decodeSections(bytes);
    version = decodeVersion(bytes).version ?? '?';
  } catch (_) {
    return;
  }
  for (final sec in secs) {
    if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
    final body = sec.bytes;
    final events = <_Ev>[];
    final roots = <_Node>[];
    walkHeapObjects<_Node>(
      body,
      onObjectOpen: (span, kind, oid, parent) {
        final n = _Node(kind, oid, parent);
        if (parent == null) {
          roots.add(n);
        } else {
          parent.children.add(n);
        }
        return n;
      },
      onRecord: (span, node) {
        final key = _keyAt(body, span.offset, span.lead);
        events.add(_Ev(span.offset, span.length, span.lead, node, key));
        final grade = heapDecodeTier(body, span.offset, span.lead, sec.tag);
        final tk = '${grade.tier.index}|$key';
        agg.bump(agg.tierKeyBytes, tk, span.length - grade.valueKindPayloadBytes);
        if (grade.valueKindPayloadBytes > 0) {
          agg.bump(agg.tierKeyBytes, '${HeapDecodeTier.valueKindKnown.index}|$key', grade.valueKindPayloadBytes);
        }
        agg.bump(agg.tierKeyCount, tk, 1);
        if (node == null) return;
        node.recordIndex++;
        if (span.lead == kHeapRecordPrefix && span.offset + 2 <= body.length) {
          final op = body[span.offset + 1];
          if (op == 0x2d && node.bounds == null) {
            node.bounds = c4FrameAt(body, span.offset, sec.tag)?.bounds;
          } else if (op == 0x22) {
            node.captionLen ??= c4FrameAt(body, span.offset, sec.tag)?.payload.length;
          }
        }
        if (span.length >= 3 && body[span.offset + 1] == 0xcb) {
          final a = decodeHeapAttr(body, span.offset);
          if (a != null && a.id == 0xcb && a.asInt != null) {
            (node.cb ??= []).add((a.width.index, a.asInt!, node.recordIndex - 1));
          }
        }
      },
    );

    for (var i = 0; i < events.length; i++) {
      final ev = events[i];
      if (!ev.key.startsWith('attr:cb:')) continue;
      final a = decodeHeapAttr(body, ev.offset);
      final v = a?.asInt;
      if (a == null || v == null) continue;
      final prev = i > 0 && identical(events[i - 1].node, ev.node) ? events[i - 1] : null;
      final next = i + 1 < events.length && identical(events[i + 1].node, ev.node) ? events[i + 1] : null;
      (agg.cbByPrevKey[prev?.key ?? '<objBoundary>'] ??= CappedHist()).add(v);
      (agg.cbByNextKey[next?.key ?? '<objBoundary>'] ??= CappedHist()).add(v);
      if (prev != null && prev.key.startsWith('attr:')) {
        final pa = decodeHeapAttr(body, prev.offset);
        final pv = pa?.asInt;
        if (pv != null) {
          agg.idTrialsPrevAttr++;
          if (pv == v) agg.bump(agg.idMatch, 'prevAttrEq', 1);
        }
      }
      switch (a.width) {
        case HeapAttrWidth.u8:
          agg.cbU8++;
          (agg.cbByteHist[0 * 4 + 0] ??= CappedHist()).add(v & 0xff);
        case HeapAttrWidth.u16:
          agg.cbU16++;
          (agg.cbByteHist[1 * 4 + 0] ??= CappedHist()).add((v >> 8) & 0xff);
          (agg.cbByteHist[1 * 4 + 1] ??= CappedHist()).add(v & 0xff);
        case HeapAttrWidth.u24:
          agg.cbU24++;
          if (v & 0xffff == 0) agg.cbU24Lo16Zero++;
          if (v & 0xff == 0) agg.cbU24Lo8Zero++;
          (agg.cbByteHist[2 * 4 + 0] ??= CappedHist()).add((v >> 16) & 0xff);
          (agg.cbByteHist[2 * 4 + 1] ??= CappedHist()).add((v >> 8) & 0xff);
          (agg.cbByteHist[2 * 4 + 2] ??= CappedHist()).add(v & 0xff);
          if (ev.node != null) {
            (agg.cbByKindU24Hi[ev.node!.kind] ??= CappedHist()).add((v >> 16) & 0xff);
          }
        case HeapAttrWidth.rgb:
          agg.cbRgb++;
        default:
          break;
      }
      (agg.cbByVersion[version] ??= CappedHist()).add(v);
    }

    void visit(_Node n) {
      final cb = n.cb;
      if (cb != null) {
        for (final (_, v, idx) in cb) {
          agg.cbPosition.add(idx > 40 ? 41 : idx);
          agg.idTrialsOid++;
          if (v == n.oid) agg.bump(agg.idMatch, 'oidEq', 1);
          final b = n.bounds;
          if (b != null) {
            agg.idTrialsBounds++;
            if (v == b.width) agg.bump(agg.idMatch, 'b.width', 1);
            if (v == b.height) agg.bump(agg.idMatch, 'b.height', 1);
            if (v == ((b.height << 16) | (b.width & 0xffff)) & 0xffffff) agg.bump(agg.idMatch, 'h16w', 1);
            if (v == ((b.width << 16) | (b.height & 0xffff)) & 0xffffff) agg.bump(agg.idMatch, 'w16h', 1);
            if ((v & 0xffff) == b.width) agg.bump(agg.idMatch, 'lo16=w', 1);
            if ((v & 0xffff) == b.height) agg.bump(agg.idMatch, 'lo16=h', 1);
            if (v == b.left || v == b.top) agg.bump(agg.idMatch, 'topOrLeft', 1);
          }
          final cl = n.captionLen;
          if (cl != null) {
            agg.idTrialsCaption++;
            if (v == cl) agg.bump(agg.idMatch, 'capLen', 1);
            if ((v & 0xff) == cl) agg.bump(agg.idMatch, 'lo8=capLen', 1);
          }
        }
        if (cb.length >= 2) {
          agg.multiCbObjects++;
          var nonDec = true, allEq = true;
          for (var i = 1; i < cb.length; i++) {
            if (cb[i].$2 < cb[i - 1].$2) nonDec = false;
            if (cb[i].$2 != cb[i - 1].$2) allEq = false;
          }
          if (nonDec) agg.multiCbNonDec++;
          if (allEq) agg.multiCbAllEqual++;
        }
      }
      final seq = [
        for (final c in n.children)
          if (c.cb != null && c.cb!.isNotEmpty) c.cb!.first.$2,
      ];
      if (seq.length >= 3) {
        agg.monoParents++;
        var nonDec = true, strict = true, allEq = true;
        for (var i = 1; i < seq.length; i++) {
          if (seq[i] < seq[i - 1]) nonDec = false;
          if (seq[i] <= seq[i - 1]) strict = false;
          if (seq[i] != seq[i - 1]) allEq = false;
        }
        if (nonDec) agg.monoNonDec++;
        if (strict) agg.monoStrictInc++;
        if (allEq) agg.monoAllEqual++;
      }
      for (final c in n.children) {
        visit(c);
      }
    }

    for (final r in roots) {
      visit(r);
    }
  }
}

String _pct(int a, int b) => b == 0 ? '-' : (100 * a / b).toStringAsFixed(2);

void _printHistTable(String title, Map<String, CappedHist> table, {int topKeys = 30, int topValues = 5}) {
  stdout.writeln('\n== $title ==');
  final keys = table.entries.toList()..sort((a, b) => b.value.total - a.value.total);
  for (final e in keys.take(topKeys)) {
    final h = e.value;
    final tv = h.top(topValues).map((x) => '${x.key}:${_pct(x.value, h.total)}%').join(' ');
    stdout.writeln(
      '  ${e.key.padRight(18)} n=${h.total.toString().padLeft(9)} distinct=${h.counts.length}'
      '${h.overflow > 0 ? '+ovf' : ''}  top: $tv',
    );
  }
  if (keys.length > topKeys) stdout.writeln('  ... ${keys.length - topKeys} more keys');
}

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final files = listCorpusVis(Directory(root));
  stdout.writeln('corpus: ${files.length} VIs under $root');
  final sw = Stopwatch()..start();

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
  stdout.writeln('probe pass: ${sw.elapsedMilliseconds} ms');

  final totalBytes = agg.tierKeyBytes.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln('\n#### GAP CENSUS (record bytes by tier|key; total=$totalBytes) ####');
  for (final tier in [1, 2]) {
    final rows = agg.tierKeyBytes.entries.where((e) => e.key.startsWith('$tier|')).toList()
      ..sort((a, b) => b.value - a.value);
    final tierTotal = rows.fold<int>(0, (a, e) => a + e.value);
    stdout.writeln(
      '\n-- tier ${tier == 1 ? 'valueKindKnown' : 'framed-only'} '
      '($tierTotal bytes = ${_pct(tierTotal, totalBytes)}% of record bytes) --',
    );
    for (final e in rows.take(40)) {
      stdout.writeln(
        '  ${e.key.substring(2).padRight(18)} bytes=${e.value.toString().padLeft(10)} '
        '(${_pct(e.value, totalBytes)}%)  count=${agg.tierKeyCount[e.key]}',
      );
    }
    if (rows.length > 40) stdout.writeln('  ... ${rows.length - 40} more');
  }

  stdout.writeln('\n#### 0xCB ####');
  stdout.writeln('widths: u8=${agg.cbU8} u16=${agg.cbU16} u24=${agg.cbU24} rgb=${agg.cbRgb}');
  stdout.writeln(
    'u24 lo16==0: ${agg.cbU24Lo16Zero} (${_pct(agg.cbU24Lo16Zero, agg.cbU24)}%)  '
    'lo8==0: ${agg.cbU24Lo8Zero} (${_pct(agg.cbU24Lo8Zero, agg.cbU24)}%)',
  );
  _printHistTable('0xCB value by PREV record key (same object)', agg.cbByPrevKey);
  _printHistTable('0xCB value by NEXT record key (same object)', agg.cbByNextKey);

  stdout.writeln('\n== byte decomposition ==');
  const names = ['u8[0]', 'u16[hi]', 'u16[lo]', 'u24[hi]', 'u24[mid]', 'u24[lo]'];
  const slots = [0, 4, 5, 8, 9, 10];
  for (var i = 0; i < slots.length; i++) {
    final h = agg.cbByteHist[slots[i]];
    if (h == null) continue;
    final tv = h.top(8).map((x) => '0x${x.key.toRadixString(16)}:${_pct(x.value, h.total)}%').join(' ');
    stdout.writeln('  ${names[i].padRight(8)} distinct=${h.counts.length}  top: $tv');
  }

  stdout.writeln('\n== identity tests ==');
  stdout.writeln(
    '  trials: bounds=${agg.idTrialsBounds} caption=${agg.idTrialsCaption} '
    'prevAttr=${agg.idTrialsPrevAttr} oid=${agg.idTrialsOid}',
  );
  final matches = agg.idMatch.entries.toList()..sort((a, b) => b.value - a.value);
  for (final e in matches) {
    final trials = switch (e.key) {
      'capLen' || 'lo8=capLen' => agg.idTrialsCaption,
      'prevAttrEq' => agg.idTrialsPrevAttr,
      'oidEq' => agg.idTrialsOid,
      _ => agg.idTrialsBounds,
    };
    stdout.writeln('  ${e.key.padRight(12)} matches=${e.value} (${_pct(e.value, trials)}%)');
  }

  stdout.writeln('\n== position within object (record index; 41 = >40) ==');
  final pos = agg.cbPosition.top(12).map((x) => '${x.key}:${_pct(x.value, agg.cbPosition.total)}%').join(' ');
  stdout.writeln('  $pos');

  stdout.writeln('\n== monotonicity ==');
  stdout.writeln(
    '  sibling groups(>=3 cb-children)=${agg.monoParents} nonDec=${agg.monoNonDec} '
    '(${_pct(agg.monoNonDec, agg.monoParents)}%) strictInc=${agg.monoStrictInc} '
    '(${_pct(agg.monoStrictInc, agg.monoParents)}%) allEqual=${agg.monoAllEqual} '
    '(${_pct(agg.monoAllEqual, agg.monoParents)}%)',
  );
  stdout.writeln(
    '  multi-cb objects=${agg.multiCbObjects} nonDec=${agg.multiCbNonDec} '
    '(${_pct(agg.multiCbNonDec, agg.multiCbObjects)}%) allEqual=${agg.multiCbAllEqual} '
    '(${_pct(agg.multiCbAllEqual, agg.multiCbObjects)}%)',
  );

  final versions = agg.cbByVersion.entries.toList()..sort((a, b) => b.value.total - a.value.total);
  stdout.writeln('\n== per-version value stability (top values per version) ==');
  for (final e in versions.take(12)) {
    final h = e.value;
    final tv = h.top(4).map((x) => '${x.key}:${_pct(x.value, h.total)}%').join(' ');
    stdout.writeln('  ${e.key.padRight(8)} n=${h.total} distinct=${h.counts.length}  $tv');
  }

  stdout.writeln('\n== u24 hi-byte by enclosing kind (top kinds) ==');
  final kinds = agg.cbByKindU24Hi.entries.toList()..sort((a, b) => b.value.total - a.value.total);
  for (final e in kinds.take(15)) {
    final h = e.value;
    final tv = h.top(6).map((x) => '0x${x.key.toRadixString(16)}:${_pct(x.value, h.total)}%').join(' ');
    stdout.writeln('  kind=0x${e.key.toRadixString(16).padRight(4)} n=${h.total} $tv');
  }
}
