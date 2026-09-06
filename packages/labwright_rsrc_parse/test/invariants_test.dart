@Tags(['corpus'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _subviKinds = {0x31, 0x32, 0xc5, 0x104, 0x103};
const _sigLen = {'RTSG': 16, 'OBSG': 16, 'CCSG': 16, 'SCSR': 20, 'MUID': 4};
const _constLen = {'VPDP': 4, 'DLDR': 28, 'GCPR': 13};
const _iconLen = {'icl8': 1024, 'icl4': 512, 'ICON': 128};

const _fuzzIters = 2;

typedef _Summ = (Map<String, int>, Map<String, Set<String>>, List<String>, Set<int>, Set<String>);

String _sig(ViModel m) {
  final b = StringBuffer();
  for (final diag in [...m.blockDiagrams, ...m.frontPanelDiagrams]) {
    b.write('§${diag.sectionTag}');
    for (final o in diag.objects) {
      final r = o.absBounds;
      b.write(
        '|${o.oid},${o.kind},${o.parentOid},'
        '${r == null ? 'n' : '${r.top}.${r.left}.${r.bottom}.${r.right}'},'
        '${o.category.index},${o.label}',
      );
    }
  }
  return b.toString();
}

bool _inside(HeapRect o, int cx, int cy) => cx >= o.left && cx <= o.right && cy >= o.top && cy <= o.bottom;
bool _heapLead(int x) => x == 0xc4 || (x >= 0x08 && x <= 0x13);
bool _wild(HeapRect r) => [r.left, r.top, r.right, r.bottom].any((c) => c < -200000 || c > 200000);

bool _structuralHeap(List<int> b) {
  if (b.length < 8) return false;
  final declared = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  return declared == b.length - 4 && _heapLead(b[4]);
}

bool _printableRun(Iterable<int> runes, {bool asciiOnly = true, double? moreThan}) {
  var printable = 0, total = 0;
  for (final c in runes) {
    total++;
    if (c == 9 || c == 10 || c == 13 || (c >= 0x20 && (asciiOnly ? c < 0x7f : c != 0xfffd))) printable++;
  }
  if (total == 0) return true;
  return moreThan == null ? printable == total : printable / total > moreThan;
}

_Summ _summarize(Uint8List bytes, String path) {
  final c = <String, int>{};
  final diags = <String>[];
  final kinds = <int>{};
  final headTags = <String>{};
  void n(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  void bad(String key, String msg) {
    n('bad:$key');
    if (diags.length < 4) diags.add('$key• $msg');
  }

  final bodies = {
    for (final t in [..._constLen.keys, 'RTSG', 'OBSG', 'CCSG', 'SCSR']) t: <String>{},
  };

  List<ViSection>? secs;
  List<DecodedSection>? dsecs;
  try {
    secs = readViSections(bytes);
  } catch (_) {}
  try {
    dsecs = decodeSections(bytes);
  } catch (_) {}

  if (secs != null) {
    final rec = saveRecordFromSections(secs);
    final vstr = decodeVersion(bytes).version;
    final vMajor = vstr == null ? null : RegExp(r'^(\d{1,2})').firstMatch(vstr)?.group(1);
    if (rec != null) {
      n('lvsrSeen');
      if (rec.stage != 0x80) n('stageNon80');
      if (vMajor != null) {
        n('verTotal');
        if (rec.versionMajor == int.parse(vMajor)) n('verMatch');
      }
      final h = rec.blockDiagramPasswordHash;
      if (h != null) {
        for (final s in secs) {
          if (s.tag != 'BDPW' || s.bytes.length < 16) continue;
          n('pwTotal');
          var same = true;
          for (var i = 0; i < 16; i++) {
            same &= h[i] == s.bytes[i];
          }
          if (same) n('pwMatch');
          break;
        }
      }
    }
    final vw = versionWordFromSections(secs);
    if (vw != null) {
      if (vMajor != null) {
        n('vwStrTot');
        if (vw.major == int.parse(vMajor)) n('vwStrEq');
      }
      if (rec != null) {
        n('vwLvsrTot');
        if (rec.versionMajor == vw.major) n('vwLvsrEq');
      }
    }

    for (final s in secs) {
      switch (s.tag) {
        case 'DTHP' when s.bytes.length >= 4:
          n('dthpTotal');
          if (s.bytes.length == 4) n('dthpFour');
          final h = decodeDataTypeHeap(s.bytes);
          if (h != null) n('dthpDecoded');
          if (h != null && h.isExtended) {
            n('dthpExt');
            if (h.names.isNotEmpty) n('dthpExtNamed');
            if (h.names.isNotEmpty && h.names.every((x) => _printableRun(x.runes))) n('dthpExtPrintable');
          }
        case 'HIST':
          n('histTotal');
          if (s.bytes.length == 40) n('histSized');
          final h = decodeHistory(s.bytes);
          if (h != null && h.formatVersion == 2) n('histVer2');
          if (h != null && h.reservedAreZero) n('histReservedZero');
        case 'HLPP':
          n('hlppTot');
          final p = decodeHelpPath(s.bytes);
          if (p != null && p.isPth0 && p.components.isNotEmpty && p.path.isNotEmpty) n('hlppOk');
        case 'HLPT' when s.bytes.length >= 4:
          n('hlptTot');
          final len = (s.bytes[0] << 24) | (s.bytes[1] << 16) | (s.bytes[2] << 8) | s.bytes[3];
          final t = decodeStringBlock(s.bytes);
          if (len == s.bytes.length - 4 && t != null && _printableRun(t.runes, moreThan: 0.9)) n('hlptOk');
        case 'FTAB':
          final t = decodeFontTable(s.bytes);
          if (t == null) break;
          n('ftabTotal');
          if (t.version == 1) n('ftabVer1');
          if (t.names.length == t.fontCount) n('ftabConsistent');
          if (t.names.every((x) => x.runes.every((r) => r == 9 || (r >= 0x20 && r < 0x7f)))) n('ftabPrintable');
        case 'NUID' || 'SUID' || 'BNID' when s.bytes.length >= 4:
          n('idTot');
          final t = decodeIdTable(s.bytes);
          if (t != null && s.bytes.length == 4 + 4 * t.count && t.entries.length == t.count) n('idFramed');
        default:
          final icon = _iconLen[s.tag];
          if (icon != null) {
            n('iconTot');
            if (s.bytes.length == icon) n('iconSized');
            final dec = decodeLegacyIcon(s.bytes, legacyIconBpp(s.tag)!);
            if (dec != null && dec.pixels.length == 1024) n('iconDecoded');
          }
          final fixedLen = _sigLen[s.tag] ?? _constLen[s.tag];
          if (fixedLen != null) {
            n('cnt:${s.tag}');
            if (s.bytes.length == fixedLen) n('sized:${s.tag}');
            bodies[s.tag]?.add(s.bytes.map((x) => x.toRadixString(16)).join());
          }
      }
    }
  }

  if (dsecs != null) {
    for (final d in dsecs) {
      if (d.tag == 'TM80') {
        final m = decodeTypeMap(d.bytes);
        if (m == null) continue;
        n('tmTotal');
        if (m.framesExactly) {
          n('tmFramed');
          final re = reserializeTypeMap(d.bytes);
          if (re == null || re.length != d.bytes.length || !_bytesEq(re, d.bytes)) n('tmReemitBad');
        }
      } else if (d.tag == 'STRG' && d.bytes.length >= 4) {
        n('strgTotal');
        final len = (d.bytes[0] << 24) | (d.bytes[1] << 16) | (d.bytes[2] << 8) | d.bytes[3];
        final text = decodeStringBlock(d.bytes);
        if (len == d.bytes.length - 4 && text != null && _printableRun(text.runes, asciiOnly: false, moreThan: 0.9)) {
          n('strgOk');
        }
      }
    }
  }

  if (secs != null && dsecs != null) {
    ViSection? conp;
    for (final s in secs) {
      if (s.tag == 'CONP') conp = s;
    }
    final pane = conp != null && conp.bytes.length == 2 ? decodeConnectorPane(conp.bytes) : null;
    if (pane?.typeIndex != null) {
      final pool = typePoolFromDecoded(dsecs);
      if (pool.isNotEmpty) {
        n('conpTotal');
        if (pane!.typeIndex! >= 1 && pane.typeIndex! <= pool.length) n('conpInRange');
      }
    }
  }

  ViModel? m;
  try {
    m = buildViModel(bytes);
  } catch (_) {}
  if (m == null) return (c, bodies, diags, kinds, headTags);

  try {
    if (_sig(m) != _sig(buildViModel(bytes))) bad('nondet', path);
  } catch (_) {}

  final decodedSections = dsecs;
  if (decodedSections != null) {
    Uint8List? bodyOf(String tag) => decodedSections.where((s) => s.tag == tag).map((s) => s.bytes).firstOrNull;
    final vctp = bodyOf('VCTP');
    final dthpBody = bodyOf('DTHP');
    final dthp = dthpBody == null ? null : decodeDataTypeHeap(dthpBody);
    final topLevel = vctp == null ? const <int>[] : decodeTypeTable(vctp);
    if (dthp != null && topLevel.isNotEmpty) {
      n('dthpBaseTot');
      if (dthp.firstTopLevelIndex + dthp.heapTypeCount - 1 == topLevel.length) n('dthpRunEndsAtTail');
      final indices = [
        for (final d in [...m.blockDiagrams, ...m.frontPanelDiagrams])
          for (final o in d.objects)
            if (o.typeDescIdx != null) o.typeDescIdx!,
      ];
      if (indices.isNotEmpty) {
        n('dthpIdxTot');
        if (indices.reduce(min) == 1) n('dthpIdxMinOne');
        if (indices.reduce(max) <= dthp.heapTypeCount) n('dthpIdxInRange');
      }
    }
  }

  for (final o in [...m.blockDiagrams, ...m.frontPanelDiagrams].expand((d) => d.objects)) {
    kinds.add(o.kind);
    final r = o.absBounds;
    if (r == null) continue;
    n('boundsChecked');
    if (_wild(r)) bad('wildBounds', 'wild coordinate in $path');
  }

  for (final d in m.frontPanelDiagrams) {
    final keys = <String>{};
    var drawnHere = 0;
    for (final o in d.objects) {
      final r = o.absBounds;
      if (r == null) continue;
      n('fpBounded');
      if (r.top < 0 || r.left < 0) n('fpNeg');
      if (r.width > 1 && r.height > 1) {
        n('fpVisible');
        if (o.category != ViObjectKind.unknown) n('fpTyped');
        if (r.isValid) {
          drawnHere++;
          keys.add('${r.top},${r.left},${r.bottom},${r.right}');
        }
      }
    }
    if (drawnHere >= 8) {
      n('drawn', drawnHere);
      n('distinct', keys.length);
    }
  }
  if ((c['fpNeg'] ?? 0) > 0) n('fpNegFiles');

  for (final o in m.blockDiagrams.expand((d) => d.objects)) {
    final r = o.absBounds;
    if (r != null && r.width > 1 && r.height > 1) {
      n('bdVisible');
      if (o.category != ViObjectKind.unknown) n('bdTyped');
    }
    if (_subviKinds.contains(o.kind)) {
      n('subviTotal');
      if (o.label != null && o.label!.trim().isNotEmpty) n('subviNamed');
    }
  }

  for (final diag in m.blockDiagrams) {
    final byOid = {for (final o in diag.objects) o.oid: o};
    for (final o in diag.objects) {
      if (o.category != ViObjectKind.node) continue;
      final b = o.absBounds;
      if (b == null || !b.isValid || b.width <= 1 || b.height <= 1) continue;
      HeapRect? frame;
      var p = o.parentOid;
      final seen = <int>{o.oid};
      while (p != null && seen.add(p)) {
        final po = byOid[p];
        if (po == null) break;
        if (po.category == ViObjectKind.structure && (po.absBounds?.isValid ?? false)) {
          frame = po.absBounds;
          break;
        }
        p = po.parentOid;
      }
      if (frame == null) continue;
      n('layoutPairs');
      if (_inside(frame, b.left + b.width ~/ 2, b.top + b.height ~/ 2)) n('layoutContained');
    }
  }

  try {
    for (final s in decodeSections(bytes)) {
      final isCatHeap = isRecordHeapTag(s.tag);
      final isStruct = _structuralHeap(s.bytes);
      if (isCatHeap) {
        headTags.add(s.tag);
        n('catHeapSections');
        if (isStruct) n('catHeapStructural');
      }
      if (isStruct) {
        n('structuralSections');
        if (isCatHeap) n('structuralCatalogued');
      }
    }
  } catch (_) {}

  if (bytes.length >= 64) {
    final rng = Random(0xC0FFEE);
    for (var iter = 0; iter < _fuzzIters && (c['bad:fuzzWild'] ?? 0) == 0; iter++) {
      final mut = Uint8List.fromList(bytes);
      final flips = 1 + rng.nextInt(3);
      for (var k = 0; k < flips; k++) {
        mut[rng.nextInt(mut.length)] ^= 1 << rng.nextInt(8);
      }
      ViModel? built;
      try {
        built = buildViModel(mut);
      } catch (_) {
        built = null;
      }
      if (built == null) continue;
      for (final o in [...built.blockDiagrams, ...built.frontPanelDiagrams].expand((d) => d.objects)) {
        final r = o.absBounds;
        if (r != null && _wild(r)) {
          bad('fuzzWild', 'corruption leaked a wild coordinate (seed VI $path, iter $iter)');
          break;
        }
      }
    }
  }

  return (c, bodies, diags, kinds, headTags);
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final Map<String, int> C;
  late final Map<String, Set<String>> bodies;
  late final List<String> diags;
  late final Set<int> kindsSeen;
  late final Set<String> headTags;
  setUpAll(() async {
    final res = await corpusParallel(all, _summarize);
    C = {};
    bodies = {};
    diags = [];
    kindsSeen = {};
    headTags = {};
    for (final (counts, b, d, k, h) in res) {
      counts.forEach((key, v) => C[key] = (C[key] ?? 0) + v);
      b.forEach((key, v) => (bodies[key] ??= {}).addAll(v));
      diags.addAll(d);
      kindsSeen.addAll(k);
      headTags.addAll(h);
    }
  });

  int L(String k) => C[k] ?? 0;
  List<String> D(String key) => diags.where((x) => x.startsWith('$key•')).take(5).toList();

  test('DETERMINISM: building the same VI twice yields an identical object graph', () {
    expect(L('bad:nondet'), 0, reason: 'non-deterministic decode: ${D('nondet')}');
  });

  test('STRUCTURAL INVARIANT: every decoded object has sane (non-wild) bounds', () {
    expect(L('bad:wildBounds'), 0, reason: D('wildBounds').join('; '));
  });

  test('MUTATION-FUZZ: byte-flipped VIs decode without hanging and never emit wild bounds', () {
    expect(L('bad:fuzzWild'), 0, reason: D('fuzzWild').join('; '));
  });

  test('CATALOG INTEGRITY: every catalogued object-class kind occurs in the corpus', () {
    for (final c in HeapObjectClass.values) {
      if (c == HeapObjectClass.unknown) continue;
      expect(
        kindsSeen.contains(c.code),
        isTrue,
        reason:
            'catalogued kind 0x${c.code.toRadixString(16)} (${c.name}) has NO corpus evidence — '
            'fabricated/dead entry, or the corpus drifted. Re-probe before keeping it.',
      );
    }
  });

  test('BLOCK CATALOG: every catalogued record-heap section really is a C4 heap', () {
    expect(
      L('catHeapStructural'),
      L('catHeapSections'),
      reason: 'a catalogued record-heap section was NOT a structural C4 heap — the recordHeap set is wrong.',
    );
    expect(headTags, containsAll(<String>{'FPHb', 'BDHb'}));
  });

  test('LVSR stage byte is always 0x80; every framed TM80 re-emits byte-exact', () {
    expect(L('stageNon80'), 0, reason: 'an LVSR stage byte != 0x80 appeared — re-probe the stage claim.');
    expect(L('tmReemitBad'), 0, reason: 'a framed TM80 did not re-emit byte-exact from its decoded fields');
  });

  test('DTHP decode is total and extended blocks recover printable names', () {
    expect(L('dthpDecoded'), L('dthpTotal'), reason: 'decodeDataTypeHeap returned null for a >=4-byte DTHP');
    expect(L('dthpExtNamed'), L('dthpExt'), reason: 'an extended DTHP recovered no names — _scanNames regressed');
    expect(L('dthpExtPrintable'), L('dthpExt'), reason: 'an extended DTHP recovered a non-printable name');
  });

  test('DTHP locates the heap type-index space in the VCTP top-level list', () {
    expect(
      L('dthpRunEndsAtTail'),
      L('dthpBaseTot'),
      reason: 'firstTopLevelIndex + heapTypeCount - 1 != topLevel.length — the heap run left the list tail',
    );
    expect(L('dthpIdxMinOne'), L('dthpIdxTot'), reason: 'a heap typeDescIndex space did not start at 1');
    expect(L('dthpIdxInRange'), L('dthpIdxTot'), reason: 'a heap typeDescIndex ran past the DTHP-declared count');
  });

  test('section-law and model censuses match the committed snapshot exactly', () {
    expectCorpusSnapshot('invariants', {
      for (final e in C.entries)
        if (!e.key.startsWith('bad:')) e.key: e.value,
      for (final e in bodies.entries) 'distinctBodies:${e.key}': e.value.length,
      'kindsSeen': kindsSeen.length,
      'headTags': headTags.length,
    });
  });
}
