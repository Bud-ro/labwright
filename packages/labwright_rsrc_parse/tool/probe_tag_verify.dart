import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Per-tag corpus verification for candidate 10-bit tag meanings.
///
/// For every target rawTagId this reports, corpus-wide: record counts per
/// width form, the ENCLOSING object's class-code histogram, the section-tag
/// histogram, and value statistics — the scope/shape evidence a rename or a
/// tier upgrade must clear. Plus targeted structural checks:
///
///   - 0xAF "masterPart": does an object in the same parent scope carry a
///     partID (0xDF) equal to the 0xAF value?
///   - 0x158 "termListLength": does the value equal the enclosing object's
///     direct-child-object count or its `14 19` ref count?
///   - 0x044 "conNum": 255-sentinel rate and small-int share.
///   - 0x114 "stamp": u32 range vs the LabVIEW 1904 epoch window.
///   - 0x0BF/0x0CA "nRC/oRC": u32 as two u16 halves, both small.
///   - `14 53` (leaf tag 52, class attr): do `fe` values land in the set of
///     class codes observed as object headers?
///   - leaf-with-attrs (`15xx/16xx/14xx`) fd-uid resolve rate per tag.
///   - 0x275 "savedSize": 8-byte payload valid-rectangle rate.
///   - 0x0FA "rtPopupString": printable-payload rate.
///   - 0x0D0 "origin" / 0x0B7 "minPaneSize": u32 as (s16,s16) plausibility.
///   - `64 CB 26` framing: open/close balance at EOF, 3-byte vs 5-byte reading.
///
/// Run: `dart run tool/probe_tag_verify.dart [corpusRoot=<pkg>/corpus/vi]`

const Set<int> kTargets = {
  0x0af, 0x1e7, 0x09f, 0x115, 0x020, 0x021, 0x022, 0x023, 0x024, 0x028, //
  0x05f, 0x0d6, 0x04c, 0x062, 0x0e9, 0x0ea, 0x0de, 0x106, 0x286, 0x158,
  0x044, 0x0da, 0x114, 0x0bf, 0x0ca, 0x0c9, 0x26c, 0x25a, 0x275, 0x25d,
  0x01f, 0x019, 0x03a, 0x089, 0x0dc, 0x061, 0x048, 0x08a, 0x17b, 0x072,
  0x128, 0x0b7, 0x02a, 0x02b, 0x0d0, 0x06f, 0x051, 0x097, 0x02e, 0x0c0,
  0x266, 0x255, 0x09a, 0x232, 0x27f, 0x280, 0x15b, 0x0ce, 0x043, 0x0dd,
  0x04d, 0x28f, 0x0fa, 0x12d, 0x027, 0x090, 0x1c0, 0x25c, 0x271, 0x277,
  0x291, 0x0b5, 0x1b3, 0x127, 0x254, 0x025, 0x0c4, 0x08c, 0x05e, 0x120,
  0x053, 0x28a, 0x289, 0x113, 0x1bd, 0x1cb, 0x1d0, 0x14b, 0x1cf, 0x1e2,
};

class Hist {
  final Map<int, int> counts = {};
  int total = 0;
  void add(int v) {
    total++;
    if (counts.length < 4096 || counts.containsKey(v)) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
  }

  void merge(Hist o) {
    total += o.total;
    o.counts.forEach((k, n) {
      if (counts.length < 4096 || counts.containsKey(k)) counts[k] = (counts[k] ?? 0) + n;
    });
  }

  List<MapEntry<int, int>> top(int n) => (counts.entries.toList()..sort((a, b) => b.value - a.value)).take(n).toList();
}

class TagStat {
  final Map<String, int> widthCounts = {};
  final Hist classes = Hist();
  final Map<String, int> sections = {};
  final Hist values = Hist();
  final Hist payloadLens = Hist();
  final Hist attrIds = Hist(); // first attr id byte for la records
  int fdResolves = 0, fdTotal = 0;
  int feClassValid = 0, feTotal = 0;

  void merge(TagStat o) {
    o.widthCounts.forEach((k, v) => widthCounts[k] = (widthCounts[k] ?? 0) + v);
    classes.merge(o.classes);
    o.sections.forEach((k, v) => sections[k] = (sections[k] ?? 0) + v);
    values.merge(o.values);
    payloadLens.merge(o.payloadLens);
    attrIds.merge(o.attrIds);
    fdResolves += o.fdResolves;
    fdTotal += o.fdTotal;
    feClassValid += o.feClassValid;
    feTotal += o.feTotal;
  }
}

class _Agg {
  final Map<int, TagStat> tags = {};
  // masterPart test
  int afTrials = 0, afParentHasDf = 0, afOwnDfEq = 0;
  // termListLength test
  int tllTrials = 0, tllEqChildren = 0, tllEqRef19 = 0;
  // conNum
  int conTrials = 0, con255 = 0, conSmall = 0;
  // stamp
  int stampTrials = 0, stampEpochWindow = 0;
  // nRC/oRC halves
  int rcTrials = 0, rcHalvesSmall = 0;
  // savedSize shape
  int ssTrials = 0, ssLen8 = 0, ssValidRect = 0;
  // rtPopupString printable
  int rtTrials = 0, rtPrintable = 0;
  // origin/minPaneSize point tests
  int d0Trials = 0, d0PlausiblePoint = 0;
  int b7Trials = 0, b7PlausiblePoint = 0;
  // cb26 balance
  int cbSections = 0, cbBalanced3 = 0, cbBalanced5 = 0;

  TagStat tag(int t) => tags[t] ??= TagStat();

  void merge(_Agg o) {
    o.tags.forEach((k, v) => tag(k).merge(v));
    afTrials += o.afTrials;
    afParentHasDf += o.afParentHasDf;
    afOwnDfEq += o.afOwnDfEq;
    tllTrials += o.tllTrials;
    tllEqChildren += o.tllEqChildren;
    tllEqRef19 += o.tllEqRef19;
    conTrials += o.conTrials;
    con255 += o.con255;
    conSmall += o.conSmall;
    stampTrials += o.stampTrials;
    stampEpochWindow += o.stampEpochWindow;
    rcTrials += o.rcTrials;
    rcHalvesSmall += o.rcHalvesSmall;
    ssTrials += o.ssTrials;
    ssLen8 += o.ssLen8;
    ssValidRect += o.ssValidRect;
    rtTrials += o.rtTrials;
    rtPrintable += o.rtPrintable;
    d0Trials += o.d0Trials;
    d0PlausiblePoint += o.d0PlausiblePoint;
    b7Trials += o.b7Trials;
    b7PlausiblePoint += o.b7PlausiblePoint;
    cbSections += o.cbSections;
    cbBalanced3 += o.cbBalanced3;
    cbBalanced5 += o.cbBalanced5;
  }
}

class _Node {
  _Node(this.kind, this.parent);
  final int kind;
  final _Node? parent;
  int childCount = 0, ref19Count = 0;
  List<int>? dfValues;
  List<(int, int)>? afValues; // (value, enclosingKind)
  List<int>? tllValues;
}

/// EOF open/close balance of [body] with the `64 cb 26` case read as [cb26Step].
int _balance(Uint8List body, int cb26Step) {
  final length = body.length;
  var i = 4, depth = 0;
  while (i < length) {
    int? step;
    if (body[i] == 0x64 && i + 3 <= length && body[i + 1] == 0xcb && body[i + 2] == 0x26) {
      step = cb26Step;
    } else {
      step = recordSkip(body, i);
    }
    if (step == null || i + step > length) return -9999;
    final lead = body[i];
    if (kHeapGroupOpenLeads.contains(lead) && i + 4 <= length && isHeapTypeTag(body[i + 3])) depth++;
    if (kHeapGroupCloseLeads.contains(lead)) depth--;
    i += step;
  }
  return depth;
}

bool _printable(int b) => b >= 0x20 && b < 0x7f;

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
    final oids = <int>{};
    final headerKinds = <int>{};
    final nodes = <_Node>[];
    final laFd = <(int, int)>[]; // (rawTag, uid) — resolve after oids known
    var sawCb26 = false;

    walkHeapObjects<_Node>(
      body,
      onObjectOpen: (span, kind, oid, parent) {
        final n = _Node(kind, parent);
        nodes.add(n);
        parent?.childCount++;
        oids.add(oid);
        headerKinds.add(kind);
        return n;
      },
      onRecord: (span, node) {
        final offset = span.offset;
        final lead = span.lead;
        if (span.length == 3 && lead == 0x64) sawCb26 = true;
        if (offset + 2 > body.length) return;
        final raw = ((lead & 3) << 8) | body[offset + 1];
        if (lead == 0x14 && raw == 0x019 && node != null) node.ref19Count++;
        if (!kTargets.contains(raw) && !(raw == 0x0df)) return;
        final kind = node?.kind ?? -1;
        final sizeSpec = lead >> 5;
        final hasAttrs = (lead >> 4) & 1;
        final scope = (lead >> 2) & 3;
        if (scope != 1) return; // leafs only; opens/closes handled by walker

        // 0xDF gathered only for the masterPart cross-test.
        if (raw == 0x0df) {
          final a = decodeHeapAttr(body, offset);
          final v = a?.asInt;
          if (v != null && node != null) (node.dfValues ??= []).add(v);
          return;
        }

        final t = agg.tag(raw);
        t.classes.add(kind);
        t.sections[sec.tag] = (t.sections[sec.tag] ?? 0) + 1;

        if (hasAttrs == 1) {
          // Leaf with attribute list: `<hdr> <count> (<atId> <value>)…`.
          t.widthCounts['la'] = (t.widthCounts['la'] ?? 0) + 1;
          if (offset + 4 <= body.length) {
            final atId = body[offset + 3];
            t.attrIds.add(atId);
            final v = (offset + 6 <= body.length) ? (body[offset + 4] << 8) | body[offset + 5] : null;
            if (v != null && (body[offset + 4] & 0x80) == 0) {
              if (atId == 0xfd) {
                t.fdTotal++;
                laFd.add((raw, v));
              } else if (atId == 0xfe) {
                t.feTotal++;
                t.values.add(v);
                if (headerKinds.contains(v)) t.feClassValid++; // provisional; re-tested below
              }
            }
          }
          return;
        }

        switch (sizeSpec) {
          case 0:
            t.widthCounts['s0'] = (t.widthCounts['s0'] ?? 0) + 1;
            t.values.add(0);
          case 7:
            t.widthCounts['b1'] = (t.widthCounts['b1'] ?? 0) + 1;
            t.values.add(1);
          case 6:
            t.widthCounts['lp'] = (t.widthCounts['lp'] ?? 0) + 1;
            // Length-prefixed payload (any `Cx` lead, u8 len with the FF->u16 escape).
            Uint8List? payload;
            if (offset + 3 <= body.length) {
              final lenByte = body[offset + 2];
              final headerLen = lenByte == 0xff ? 5 : 3;
              final len = lenByte == 0xff
                  ? (offset + 5 <= body.length ? (body[offset + 3] << 8) | body[offset + 4] : -1)
                  : lenByte;
              if (len >= 0 && offset + headerLen + len <= body.length) {
                payload = Uint8List.sublistView(body, offset + headerLen, offset + headerLen + len);
              }
            }
            if (payload != null) {
              t.payloadLens.add(payload.length > 64 ? 65 : payload.length);
              if (raw == 0x275) {
                agg.ssTrials++;
                if (payload.length == 8) {
                  agg.ssLen8++;
                  final r = HeapRect.fromPayload(payload);
                  if (r != null && r.isValid) agg.ssValidRect++;
                }
              }
              if (raw == 0x0fa) {
                agg.rtTrials++;
                if (payload.isNotEmpty && payload.where(_printable).length / payload.length >= 0.9) {
                  agg.rtPrintable++;
                }
              }
            }
          default:
            final a = decodeHeapAttr(body, offset);
            final v = a?.asInt;
            if (a == null || v == null) return;
            t.widthCounts['u$sizeSpec'] = (t.widthCounts['u$sizeSpec'] ?? 0) + 1;
            t.values.add(v);
            switch (raw) {
              case 0x0af:
                if (node != null) (node.afValues ??= []).add((v, kind));
              case 0x158:
                if (node != null) (node.tllValues ??= []).add(v);
              case 0x044:
                agg.conTrials++;
                if (v == 255) agg.con255++;
                if (v < 40) agg.conSmall++;
              case 0x114:
                agg.stampTrials++;
                // LabVIEW epoch 1904-01-01; 1995..2030 ≈ 2.87e9..3.97e9.
                if (v >= 2870000000 && v <= 3970000000) agg.stampEpochWindow++;
              case 0x0bf || 0x0ca:
                agg.rcTrials++;
                if ((v >> 16) < 4096 && (v & 0xffff) < 4096) agg.rcHalvesSmall++;
              case 0x0d0:
                if (a.width == HeapAttrWidth.rgb) {
                  agg.d0Trials++;
                  final y = (v >> 16).toSigned(16), x = (v & 0xffff).toSigned(16);
                  if (y.abs() < 4096 && x.abs() < 4096) agg.d0PlausiblePoint++;
                }
              case 0x0b7:
                if (a.width == HeapAttrWidth.rgb) {
                  agg.b7Trials++;
                  final h = (v >> 16).toSigned(16), w = (v & 0xffff).toSigned(16);
                  if (h > 0 && w > 0 && h < 4096 && w < 4096) agg.b7PlausiblePoint++;
                }
            }
        }
      },
    );

    // fd-uid resolve rates.
    for (final (raw, uid) in laFd) {
      if (oids.contains(uid)) agg.tag(raw).fdResolves++;
    }

    // masterPart + termListLength post-pass.
    for (final n in nodes) {
      final af = n.afValues;
      if (af != null) {
        for (final (v, _) in af) {
          agg.afTrials++;
          if (n.dfValues?.contains(v) ?? false) agg.afOwnDfEq++;
          // any object in the same parent scope (parent's subtree, one level:
          // the parent's direct children) with partID == v?
          final parent = n.parent;
          var found = false;
          if (parent != null) {
            for (final sib in nodes) {
              if (identical(sib.parent, parent) && (sib.dfValues?.contains(v) ?? false)) {
                found = true;
                break;
              }
            }
          }
          if (found) agg.afParentHasDf++;
        }
      }
      final tll = n.tllValues;
      if (tll != null) {
        for (final v in tll) {
          agg.tllTrials++;
          if (v == n.childCount) agg.tllEqChildren++;
          if (v == n.ref19Count) agg.tllEqRef19++;
        }
      }
    }

    if (sawCb26) {
      agg.cbSections++;
      if (_balance(body, 3) == 0) agg.cbBalanced3++;
      if (_balance(body, 5) == 0) agg.cbBalanced5++;
    }
  }
}

String _pct(int a, int b) => b == 0 ? '-' : (100 * a / b).toStringAsFixed(2);
String _hx(int v) => '0x${v.toRadixString(16)}';

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

  final keys = agg.tags.keys.toList()..sort();
  for (final raw in keys) {
    final t = agg.tags[raw]!;
    final n = t.classes.total;
    stdout.writeln('\n== raw ${_hx(raw)} (tagId ${raw - 31})  n=$n ==');
    stdout.writeln('  widths: ${t.widthCounts.entries.map((e) => '${e.key}:${e.value}').join(' ')}');
    stdout.writeln(
      '  classes: ${t.classes.top(8).map((e) => '${_hx(e.key)}:${_pct(e.value, n)}%').join(' ')} '
      '(distinct=${t.classes.counts.length})',
    );
    stdout.writeln('  sections: ${t.sections.entries.map((e) => '${e.key}:${e.value}').join(' ')}');
    if (t.values.total > 0) {
      stdout.writeln(
        '  values: distinct=${t.values.counts.length} '
        'top ${t.values.top(8).map((e) => '${e.key}:${_pct(e.value, t.values.total)}%').join(' ')}',
      );
    }
    if (t.payloadLens.total > 0) {
      stdout.writeln(
        '  payloadLens(65=>64+): ${t.payloadLens.top(8).map((e) => '${e.key}:${_pct(e.value, t.payloadLens.total)}%').join(' ')}',
      );
    }
    if (t.attrIds.total > 0) {
      stdout.writeln(
        '  la attrIds: ${t.attrIds.top(4).map((e) => '${_hx(e.key)}:${e.value}').join(' ')} '
        'fdResolve=${t.fdResolves}/${t.fdTotal} (${_pct(t.fdResolves, t.fdTotal)}%) '
        'feClassValid=${t.feClassValid}/${t.feTotal}',
      );
    }
  }

  stdout.writeln('\n#### special checks ####');
  stdout.writeln(
    'masterPart(0xAF): trials=${agg.afTrials} parentScopeHasDf=${agg.afParentHasDf} '
    '(${_pct(agg.afParentHasDf, agg.afTrials)}%) ownObjectDfEq=${agg.afOwnDfEq} '
    '(${_pct(agg.afOwnDfEq, agg.afTrials)}%)',
  );
  stdout.writeln(
    'termListLength(0x158): trials=${agg.tllTrials} ==childCount=${agg.tllEqChildren} '
    '(${_pct(agg.tllEqChildren, agg.tllTrials)}%) ==ref19Count=${agg.tllEqRef19} '
    '(${_pct(agg.tllEqRef19, agg.tllTrials)}%)',
  );
  stdout.writeln(
    'conNum(0x044): trials=${agg.conTrials} v==255=${agg.con255} (${_pct(agg.con255, agg.conTrials)}%) '
    'v<40=${agg.conSmall} (${_pct(agg.conSmall, agg.conTrials)}%)',
  );
  stdout.writeln(
    'stamp(0x114): trials=${agg.stampTrials} in1995..2030window=${agg.stampEpochWindow} '
    '(${_pct(agg.stampEpochWindow, agg.stampTrials)}%)',
  );
  stdout.writeln(
    'nRC/oRC(0x0BF/0x0CA): trials=${agg.rcTrials} halves<4096=${agg.rcHalvesSmall} '
    '(${_pct(agg.rcHalvesSmall, agg.rcTrials)}%)',
  );
  stdout.writeln(
    'savedSize(0x275): trials=${agg.ssTrials} len8=${agg.ssLen8} validRect=${agg.ssValidRect} '
    '(${_pct(agg.ssValidRect, agg.ssTrials)}%)',
  );
  stdout.writeln(
    'rtPopupString(0x0FA): trials=${agg.rtTrials} printable=${agg.rtPrintable} '
    '(${_pct(agg.rtPrintable, agg.rtTrials)}%)',
  );
  stdout.writeln(
    'origin(0x0D0 rgb-width): trials=${agg.d0Trials} plausiblePoint=${agg.d0PlausiblePoint} '
    '(${_pct(agg.d0PlausiblePoint, agg.d0Trials)}%)',
  );
  stdout.writeln(
    'minPaneSize(0x0B7 rgb-width): trials=${agg.b7Trials} plausibleSizePair=${agg.b7PlausiblePoint} '
    '(${_pct(agg.b7PlausiblePoint, agg.b7Trials)}%)',
  );
  stdout.writeln(
    'cb26 balance: sections=${agg.cbSections} balancedAtEof(3B)=${agg.cbBalanced3} '
    '(${_pct(agg.cbBalanced3, agg.cbSections)}%) balancedAtEof(5B)=${agg.cbBalanced5} '
    '(${_pct(agg.cbBalanced5, agg.cbSections)}%)',
  );
}
