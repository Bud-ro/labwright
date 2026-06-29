@Tags(['corpus'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// NEW test *types* that go beyond example-based + count-pin coverage:
///
/// 1. DETERMINISM — `buildViModel` is a pure function of its bytes; building the
///    same VI twice must yield a byte-identical object graph. This is the guard
///    for the whole class of non-deterministic-decode bugs (e.g. the reverted
///    inflateSection buffer-aliasing corruption).
/// 2. STRUCTURAL INVARIANTS — properties our decode/understanding implies must
///    hold over EVERY corpus VI: unique oids per diagram, sane bounds, and
///    acyclic parent chains (a stronger statement than the crafted-cycle tests).
/// 3. RENDER-COMPLETENESS RATCHET — the fraction of visible block-diagram objects
///    that classify to a real typed widget, asserted at-or-above a floor so the
///    display can only improve. Pushes toward 100% display.
///
/// Corpus-tagged: skipped automatically when the pinned corpus isn't fetched.
String _sig(ViModel m) {
  final b = StringBuffer();
  for (final diag in [...m.blockDiagrams, ...m.frontPanelDiagrams]) {
    b.write('§${diag.sectionTag}');
    for (final o in diag.objects) {
      final r = o.absBounds;
      b.write('|${o.oid},${o.kind},${o.parentOid},'
          '${r == null ? 'n' : '${r.top}.${r.left}.${r.bottom}.${r.right}'},'
          '${o.category.index},${o.label}');
    }
  }
  return b.toString();
}

const _subviKinds = {0x31, 0x32, 0xc5, 0x104, 0x103};
bool _inside(HeapRect o, int cx, int cy) => cx >= o.left && cx <= o.right && cy >= o.top && cy <= o.bottom;

/// Deterministic byte-flip iterations fuzzed per VI in the shared pass. Every VI
/// in the corpus is fuzzed (no seed sampling), so a small per-VI iteration count
/// already yields far more fuzz coverage than the old 40-seed loop while keeping
/// the shared pass fast.
const _fuzzIters = 2;

bool _heapLead(int x) => x == 0xc4 || (x >= 0x08 && x <= 0x13);

/// A real C4 record-heap opens with a u32 content-length == len-4 followed by a
/// group-open/C4 lead (the load-bearing gate for the record walk).
bool _structuralHeap(List<int> b) {
  if (b.length < 8) return false;
  final declared = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  return declared == b.length - 4 && _heapLead(b[4]);
}

/// Per-VI summary for every `buildViModel`-based invariant. Computed ONCE per VI
/// in a worker isolate (see [corpusParallel]); the model tests below assert on the
/// aggregate of these instead of each rebuilding the whole corpus. Fields are all
/// sendable (ints/bools/`List<int>`). A VI whose model build throws (a non-RSRC
/// fixture) returns a neutral summary so it affects no aggregate.
class _M {
  final String path;
  final bool deterministic;
  final int boundsChecked;
  final String? boundsWild;
  final int fpBounded, fpNeg;
  final bool fpHasNeg;
  final int drawn, distinct;
  final int bdVisible, bdTyped;
  final int fpVisible, fpTyped;
  final int subviTotal, subviNamed;
  final int layoutPairs, layoutContained;
  final List<int> kinds;
  /// The first wild coordinate a byte-flipped rebuild leaked (null if every fuzz
  /// iteration stayed in-bounds or threw cleanly).
  final String? fuzzWild;

  /// Per-VI section census for the record-heap gate (BLOCK CATALOG ↔ corpus).
  final int catHeapSections, catHeapStructural, structuralSections, structuralCatalogued;
  final List<String> headTags;
  const _M({
    required this.path,
    required this.deterministic,
    required this.boundsChecked,
    required this.boundsWild,
    required this.fpBounded,
    required this.fpNeg,
    required this.fpHasNeg,
    required this.drawn,
    required this.distinct,
    required this.bdVisible,
    required this.bdTyped,
    required this.fpVisible,
    required this.fpTyped,
    required this.subviTotal,
    required this.subviNamed,
    required this.layoutPairs,
    required this.layoutContained,
    required this.kinds,
    required this.fuzzWild,
    required this.catHeapSections,
    required this.catHeapStructural,
    required this.structuralSections,
    required this.structuralCatalogued,
    required this.headTags,
  });
  factory _M.neutral(String path) => _M(
        path: path, deterministic: true, boundsChecked: 0, boundsWild: null, fpBounded: 0,
        fpNeg: 0, fpHasNeg: false, drawn: 0, distinct: 0, bdVisible: 0, bdTyped: 0,
        fpVisible: 0, fpTyped: 0, subviTotal: 0, subviNamed: 0, layoutPairs: 0,
        layoutContained: 0, kinds: const <int>[], fuzzWild: null, catHeapSections: 0,
        catHeapStructural: 0, structuralSections: 0, structuralCatalogued: 0,
        headTags: const <String>[],
      );
}

_M _modelSumm(Uint8List bytes, String path) {
  final ViModel m;
  try {
    m = buildViModel(bytes);
  } catch (_) {
    return _M.neutral(path);
  }
  var deterministic = true;
  try {
    deterministic = _sig(m) == _sig(buildViModel(bytes));
  } catch (_) {}

  var boundsChecked = 0;
  String? boundsWild;
  final kinds = <int>{};
  for (final o in [...m.blockDiagrams, ...m.frontPanelDiagrams].expand((d) => d.objects)) {
    kinds.add(o.kind);
    final r = o.absBounds;
    if (r == null) continue;
    boundsChecked++;
    for (final c in [r.left, r.top, r.right, r.bottom]) {
      if (c < -200000 || c > 200000) boundsWild ??= 'wild coordinate $c in $path';
    }
  }

  var fpBounded = 0, fpNeg = 0, fpVisible = 0, fpTyped = 0, drawn = 0, distinct = 0;
  var fpHasNeg = false;
  for (final d in m.frontPanelDiagrams) {
    final keys = <String>{};
    var n = 0;
    for (final o in d.objects) {
      final r = o.absBounds;
      if (r == null) continue;
      fpBounded++;
      if (r.top < 0 || r.left < 0) {
        fpNeg++;
        fpHasNeg = true;
      }
      if (r.width > 1 && r.height > 1) {
        fpVisible++;
        if (o.category != ViObjectKind.unknown) fpTyped++;
      }
      if (r.isValid && r.width > 1 && r.height > 1) {
        n++;
        keys.add('${r.top},${r.left},${r.bottom},${r.right}');
      }
    }
    if (n >= 8) {
      drawn += n;
      distinct += keys.length;
    }
  }

  var bdVisible = 0, bdTyped = 0, subviTotal = 0, subviNamed = 0;
  for (final o in m.blockDiagrams.expand((d) => d.objects)) {
    final r = o.absBounds;
    if (r != null && r.width > 1 && r.height > 1) {
      bdVisible++;
      if (o.category != ViObjectKind.unknown) bdTyped++;
    }
    if (_subviKinds.contains(o.kind)) {
      subviTotal++;
      if (o.label != null && o.label!.trim().isNotEmpty) subviNamed++;
    }
  }

  var layoutPairs = 0, layoutContained = 0;
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
      layoutPairs++;
      if (_inside(frame, b.left + b.width ~/ 2, b.top + b.height ~/ 2)) layoutContained++;
    }
  }

  var catHeapSections = 0, catHeapStructural = 0, structuralSections = 0, structuralCatalogued = 0;
  final headTags = <String>{};
  try {
    for (final s in decodeSections(bytes)) {
      final isCatHeap = isRecordHeapTag(s.tag);
      final isStruct = _structuralHeap(s.bytes);
      if (isCatHeap) {
        headTags.add(s.tag);
        catHeapSections++;
        if (isStruct) catHeapStructural++;
      }
      if (isStruct) {
        structuralSections++;
        if (isCatHeap) structuralCatalogued++;
      }
    }
  } catch (_) {}

  String? fuzzWild;
  if (bytes.length >= 64) {
    final rng = Random(0xC0FFEE);
    for (var iter = 0; iter < _fuzzIters && fuzzWild == null; iter++) {
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
        if (r == null) continue;
        for (final c in [r.left, r.top, r.right, r.bottom]) {
          if (c < -200000 || c > 200000) {
            fuzzWild = 'corruption leaked a wild coordinate $c (seed VI $path, iter $iter)';
            break;
          }
        }
        if (fuzzWild != null) break;
      }
    }
  }

  return _M(
    path: path,
    deterministic: deterministic,
    boundsChecked: boundsChecked,
    boundsWild: boundsWild,
    fpBounded: fpBounded,
    fpNeg: fpNeg,
    fpHasNeg: fpHasNeg,
    drawn: drawn,
    distinct: distinct,
    bdVisible: bdVisible,
    bdTyped: bdTyped,
    fpVisible: fpVisible,
    fpTyped: fpTyped,
    subviTotal: subviTotal,
    subviNamed: subviNamed,
    layoutPairs: layoutPairs,
    layoutContained: layoutContained,
    kinds: kinds.toList(),
    fuzzWild: fuzzWild,
    catHeapSections: catHeapSections,
    catHeapStructural: catHeapStructural,
    structuralSections: structuralSections,
    structuralCatalogued: structuralCatalogued,
    headTags: headTags.toList(),
  );
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final List<_M> M;
  setUpAll(() async {
    M = await corpusParallel(all, _modelSumm);
  });

  test('DETERMINISM: building the same VI twice yields an identical object graph', () {
    final bad = M.where((m) => !m.deterministic).map((m) => m.path).toList();
    expect(bad, isEmpty, reason: 'non-deterministic decode: ${bad.take(5).join(', ')}');
  });

  test('STRUCTURAL INVARIANT: every decoded object has sane (non-wild) bounds', () {
    final wild = M.map((m) => m.boundsWild).whereType<String>().toList();
    expect(wild, isEmpty, reason: wild.take(5).join('; '));
    expect(M.fold<int>(0, (a, m) => a + m.boundsChecked), greaterThan(0));
  });

  test('STRUCTURAL INVARIANT: front-panel coords may be negative (parked off-panel) and survive', () {
    final bounded = M.fold<int>(0, (a, m) => a + m.fpBounded);
    final negObjs = M.fold<int>(0, (a, m) => a + m.fpNeg);
    final filesWithNeg = M.where((m) => m.fpHasNeg).length;
    expect(bounded, greaterThan(0));
    expect(negObjs, greaterThan(0), reason: 'no negative FP coords survived — parked controls may be clamped');
    expect(filesWithNeg, greaterThan(0));
  });

  test('STRUCTURAL INVARIANT: drawn FP objects are distinctly placed (overlap is layout, not a collapse)', () {
    final drawn = M.fold<int>(0, (a, m) => a + m.drawn);
    final distinct = M.fold<int>(0, (a, m) => a + m.distinct);
    expect(drawn, greaterThan(0));
    expect(distinct / drawn, greaterThan(0.55),
        reason: 'drawn FP objects collapsed to shared rects: only $distinct/$drawn distinct');
  });

  test('RENDER RATCHET: visible block-diagram objects classify to a typed widget (>= floor)', () {
    final visible = M.fold<int>(0, (a, m) => a + m.bdVisible);
    final typed = M.fold<int>(0, (a, m) => a + m.bdTyped);
    expect(visible, greaterThan(0));
    final frac = typed / visible;
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'BD render-typed fraction dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%).');
  });

  test('RENDER RATCHET: visible FRONT-PANEL objects classify to a typed widget (>= floor)', () {
    final visible = M.fold<int>(0, (a, m) => a + m.fpVisible);
    final typed = M.fold<int>(0, (a, m) => a + m.fpTyped);
    expect(visible, greaterThan(0));
    final frac = typed / visible;
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'FP render-typed fraction dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%).');
  });

  test('NAMING RATCHET: subVI-call nodes recover their called-VI name (>= floor)', () {
    final total = M.fold<int>(0, (a, m) => a + m.subviTotal);
    final named = M.fold<int>(0, (a, m) => a + m.subviNamed);
    expect(total, greaterThan(0));
    final frac = named / total;
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'subVI-call name recovery dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%) — '
            'the 0xa-caption propagation likely regressed.');
  });

  test('LAYOUT RATCHET: BD nodes sit inside their enclosing structure frame (>= floor)', () {
    final pairs = M.fold<int>(0, (a, m) => a + m.layoutPairs);
    final contained = M.fold<int>(0, (a, m) => a + m.layoutContained);
    expect(pairs, greaterThan(0));
    final frac = contained / pairs;
    expect(frac, greaterThanOrEqualTo(0.98),
        reason: 'node-in-structure containment dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 98%) — '
            'coordinate composition / re-anchor likely regressed.');
  });

  test('MUTATION-FUZZ: byte-flipped VIs decode without hanging and never emit wild bounds', () {
    final wild = M.map((m) => m.fuzzWild).whereType<String>().toList();
    expect(wild, isEmpty, reason: wild.take(5).join('; '));
  });

  test('CATALOG INTEGRITY: every catalogued object-class kind occurs in the corpus', () {
    final seen = <int>{for (final m in M) ...m.kinds};
    for (final c in HeapObjectClass.values) {
      if (c == HeapObjectClass.unknown) continue;
      expect(seen.contains(c.code), isTrue,
          reason: 'catalogued kind 0x${c.code.toRadixString(16)} (${c.name}) has NO corpus evidence — '
              'fabricated/dead entry, or the corpus drifted. Re-probe before keeping it.');
    }
  });

  test('BLOCK CATALOG: every catalogued record-heap section really is a C4 heap (and only those)', () {
    final headTags = <String>{for (final m in M) ...m.headTags};
    final catHeapSections = M.fold<int>(0, (a, m) => a + m.catHeapSections);
    final catHeapStructural = M.fold<int>(0, (a, m) => a + m.catHeapStructural);
    final structuralSections = M.fold<int>(0, (a, m) => a + m.structuralSections);
    final structuralCatalogued = M.fold<int>(0, (a, m) => a + m.structuralCatalogued);
    expect(catHeapSections, greaterThan(0));
    expect(catHeapStructural, catHeapSections,
        reason: 'a catalogued record-heap section was NOT a structural C4 heap — the recordHeap set is wrong.');
    expect(headTags, containsAll(<String>{'FPHb', 'BDHb'}));
    expect(structuralSections, greaterThan(0));
    expect(structuralCatalogued / structuralSections, greaterThan(0.97),
        reason: 'structural heaps not catalogued as recordHeap: only $structuralCatalogued/$structuralSections — '
            'a real heap tag may be missing from the catalog.');
  });

  test('LVSR: decoded version matches vers, and the @96 hash mirrors BDPW', () {
    var verTotal = 0, verMatch = 0, pwTotal = 0, pwMatch = 0, stageNon80 = 0, lvsrSeen = 0;
    for (final f in all) {
      final bytes = f.readAsBytesSync();
      final List<ViSection> secs;
      try {
        secs = readViSections(bytes);
      } catch (_) {
        continue;
      }
      final rec = saveRecordFromSections(secs);
      if (rec == null) continue;
      lvsrSeen++;
      if (rec.stage != 0x80) stageNon80++;
      final vstr = decodeVersion(bytes).version;
      if (vstr != null) {
        final m = RegExp(r'^(\d{1,2})').firstMatch(vstr);
        if (m != null) {
          verTotal++;
          if (rec.versionMajor == int.parse(m.group(1)!)) verMatch++;
        }
      }
      final h = rec.blockDiagramPasswordHash;
      if (h != null) {
        for (final s in secs) {
          if (s.tag != 'BDPW' || s.bytes.length < 16) continue;
          pwTotal++;
          var same = true;
          for (var i = 0; i < 16; i++) {
            if (h[i] != s.bytes[i]) {
              same = false;
              break;
            }
          }
          if (same) pwMatch++;
          break;
        }
      }
    }
    expect(lvsrSeen, greaterThan(0));
    expect(verTotal, greaterThan(0));
    expect(verMatch / verTotal, greaterThan(0.99),
        reason: 'LVSR version major disagreed with vers in too many VIs ($verMatch/$verTotal).');
    expect(pwTotal, greaterThan(0));
    expect(pwMatch / pwTotal, greaterThan(0.99),
        reason: 'LVSR @96 hash did not mirror BDPW in too many VIs ($pwMatch/$pwTotal).');
    expect(stageNon80, 0, reason: 'an LVSR stage byte != 0x80 appeared ($stageNon80) — re-probe the stage claim.');
  });

  test('CONP: the 2-byte connector-pane index resolves in-range against VCTP (CONP only)', () {
    var total = 0, inRange = 0;
    for (final f in all) {
      final bytes = f.readAsBytesSync();
      final List<ViSection> secs;
      final List<DecodedSection> dsecs;
      try {
        secs = readViSections(bytes);
        dsecs = decodeSections(bytes);
      } catch (_) {
        continue;
      }
      ViSection? conp;
      for (final s in secs) {
        if (s.tag == 'CONP') conp = s;
      }
      if (conp == null || conp.bytes.length != 2) continue;
      final pane = decodeConnectorPane(conp.bytes);
      if (pane?.typeIndex == null) continue;
      final pool = typePoolFromDecoded(dsecs);
      if (pool.isEmpty) continue;
      total++;
      if (pane!.typeIndex! >= 1 && pane.typeIndex! <= pool.length) inRange++;
    }
    expect(total, greaterThan(0));
    expect(inRange / total, greaterThan(0.999),
        reason: 'CONP index out of VCTP range in too many VIs ($inRange/$total; corpus 100%) — '
            'the index base/encoding may have drifted.');
  });

  test('TM80: the short-form layout covers most type maps and is self-consistent', () {
    var total = 0, shortForm = 0;
    for (final f in all) {
      final List<DecodedSection> dsecs;
      try {
        dsecs = decodeSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final d in dsecs) {
        if (d.tag != 'TM80') continue;
        final m = decodeTypeMap(d.bytes);
        if (m == null) continue;
        total++;
        if (m.isShortForm) {
          shortForm++;
          expect(m.entries.length, m.count);
        }
      }
    }
    expect(total, greaterThan(0));
    expect(shortForm / total, greaterThan(0.65),
        reason: 'TM80 short-form coverage dropped to $shortForm/$total (<65%; corpus ≈70.7%).');
  });

  test('STRG: every description block is [u32 len][printable text]', () {
    var total = 0, ok = 0;
    for (final f in all) {
      final List<DecodedSection> dsecs;
      try {
        dsecs = decodeSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final d in dsecs) {
        if (d.tag != 'STRG' || d.bytes.length < 4) continue;
        total++;
        final len = (d.bytes[0] << 24) | (d.bytes[1] << 16) | (d.bytes[2] << 8) | d.bytes[3];
        final text = decodeStringBlock(d.bytes);
        if (len == d.bytes.length - 4 && text != null) {
          var printable = 0;
          for (final cu in text.runes) {
            if (cu == 9 || cu == 10 || cu == 13 || (cu >= 0x20 && cu != 0xfffd)) printable++;
          }
          if (text.isEmpty || printable / text.runes.length > 0.9) ok++;
        }
      }
    }
    expect(total, greaterThan(0));
    expect(ok / total, greaterThan(0.99),
        reason: 'STRG length-law/printability held for only $ok/$total (<99%).');
  });

  test('DTHP: the 4-byte header form dominates and decode is total', () {
    var total = 0, fourByte = 0, decoded = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag != 'DTHP' || s.bytes.length < 4) continue;
        total++;
        if (s.bytes.length == 4) fourByte++;
        if (decodeDataTypeHeap(s.bytes) != null) decoded++;
      }
    }
    expect(total, greaterThan(0));
    expect(decoded, total, reason: 'decodeDataTypeHeap returned null for a >=4-byte DTHP');
    expect(fourByte / total, greaterThan(0.97),
        reason: 'DTHP 4-byte dominance dropped to $fourByte/$total (<97%; corpus ≈99.45%).');
  });

  test('DTHP: every extended-form block recovers >=1 printable named item', () {
    var ext = 0, named = 0, printable = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag != 'DTHP' || s.bytes.length <= 4) continue;
        final h = decodeDataTypeHeap(s.bytes);
        if (h == null || !h.isExtended) continue;
        ext++;
        if (h.names.isNotEmpty) named++;
        if (h.names.isNotEmpty &&
            h.names.every((n) => n.runes.every(
                (c) => c == 9 || c == 10 || c == 13 || (c >= 0x20 && c < 0x7f)))) {
          printable++;
        }
      }
    }
    expect(ext, greaterThan(0), reason: 'no extended DTHP found — corpus changed?');
    expect(named, ext, reason: 'an extended DTHP recovered no names ($named/$ext) — _scanNames regressed');
    expect(printable, ext, reason: 'an extended DTHP recovered a non-printable name ($printable/$ext)');
  });

  test('HIST: fixed 40-byte record, version 2, reserved words zero', () {
    var total = 0, sized = 0, ver2 = 0, reservedZero = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag != 'HIST') continue;
        total++;
        if (s.bytes.length == 40) sized++;
        final h = decodeHistory(s.bytes);
        if (h == null) continue;
        if (h.formatVersion == 2) ver2++;
        if (h.reservedAreZero) reservedZero++;
      }
    }
    expect(total, greaterThan(0));
    expect(sized / total, greaterThan(0.99), reason: 'HIST not 40 bytes in $sized/$total');
    expect(ver2 / total, greaterThan(0.99), reason: 'HIST @0 != 2 in too many ($ver2/$total)');
    expect(reservedZero / total, greaterThan(0.99), reason: 'HIST reserved words non-zero in too many ($reservedZero/$total)');
  });

  test('HLPP is a parseable PTH0 path; HLPT is [u32 len][printable text]', () {
    var hlppTot = 0, hlppOk = 0, hlptTot = 0, hlptOk = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag == 'HLPP') {
          hlppTot++;
          final p = decodeHelpPath(s.bytes);
          if (p != null && p.isPth0 && p.components.isNotEmpty && p.path.isNotEmpty) hlppOk++;
        }
        if (s.tag == 'HLPT' && s.bytes.length >= 4) {
          hlptTot++;
          final len = (s.bytes[0] << 24) | (s.bytes[1] << 16) | (s.bytes[2] << 8) | s.bytes[3];
          final t = decodeStringBlock(s.bytes);
          final printable = t != null &&
              (t.isEmpty || t.runes.where((c) => c == 9 || c == 10 || c == 13 || (c >= 0x20 && c < 0x7f)).length / t.runes.length > 0.9);
          if (len == s.bytes.length - 4 && printable) hlptOk++;
        }
      }
    }
    expect(hlppTot, greaterThan(0));
    expect(hlppOk / hlppTot, greaterThan(0.99), reason: 'HLPP PTH0 parse failed in too many ($hlppOk/$hlppTot)');
    expect(hlptTot, greaterThan(0));
    expect(hlptOk / hlptTot, greaterThan(0.99), reason: 'HLPT length-law/printability failed in too many ($hlptOk/$hlptTot)');
  });

  test('FTAB: version 1 and the font-name table is self-consistent', () {
    var total = 0, ver1 = 0, consistent = 0, printable = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag != 'FTAB') continue;
        final t = decodeFontTable(s.bytes);
        if (t == null) continue;
        total++;
        if (t.version == 1) ver1++;
        if (t.names.length == t.fontCount) consistent++;
        if (t.names.every((n) => n.runes.every((c) => c == 9 || (c >= 0x20 && c < 0x7f)))) printable++;
      }
    }
    expect(total, greaterThan(0));
    expect(ver1 / total, greaterThan(0.99), reason: 'FTAB version != 1 in too many ($ver1/$total)');
    expect(consistent / total, greaterThan(0.95),
        reason: 'FTAB recovered-names != fontCount in too many ($consistent/$total) — framing drift.');
    expect(printable / total, greaterThan(0.95), reason: 'FTAB names not printable in too many ($printable/$total)');
  });

  test('icl8/icl4/ICON are exact 32x32 bitmaps decoding to 1024 pixels', () {
    final wantBytes = <String, int>{'icl8': 1024, 'icl4': 512, 'ICON': 128};
    var tot = 0, sized = 0, decoded = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        final want = wantBytes[s.tag];
        if (want == null) continue;
        tot++;
        if (s.bytes.length == want) sized++;
        final dec = decodeLegacyIcon(s.bytes, legacyIconBpp(s.tag)!);
        if (dec != null && dec.pixels.length == 1024) decoded++;
      }
    }
    expect(tot, greaterThan(0));
    expect(sized / tot, greaterThan(0.99), reason: 'legacy icon not its exact size in $sized/$tot');
    expect(decoded / tot, greaterThan(0.99), reason: 'legacy icon did not decode to 1024 px in $decoded/$tot');
  });

  test('vers binary version word matches the ASCII string and the LVSR word', () {
    var strTot = 0, strEq = 0, lvsrTot = 0, lvsrEq = 0;
    for (final f in all) {
      final bytes = f.readAsBytesSync();
      final List<ViSection> secs;
      try {
        secs = readViSections(bytes);
      } catch (_) {
        continue;
      }
      final vw = versionWordFromSections(secs);
      if (vw == null) continue;
      final vstr = decodeVersion(bytes).version;
      if (vstr != null) {
        final m = RegExp(r'^(\d{1,2})').firstMatch(vstr);
        if (m != null) {
          strTot++;
          if (vw.major == int.parse(m.group(1)!)) strEq++;
        }
      }
      final rec = saveRecordFromSections(secs);
      if (rec != null) {
        lvsrTot++;
        if (rec.versionMajor == vw.major) lvsrEq++;
      }
    }
    expect(strTot, greaterThan(0));
    expect(strEq / strTot, greaterThan(0.99), reason: 'vers word major != ASCII major in too many ($strEq/$strTot)');
    expect(lvsrTot, greaterThan(0));
    expect(lvsrEq / lvsrTot, greaterThan(0.999), reason: 'vers word major != LVSR major in too many ($lvsrEq/$lvsrTot; corpus 100%)');
  });

  test('signature blocks: fixed sizes + the varied-vs-constant split holds', () {
    final wantLen = <String, int>{'RTSG': 16, 'OBSG': 16, 'CCSG': 16, 'SCSR': 20, 'MUID': 4};
    final counts = {for (final k in wantLen.keys) k: 0};
    final sized = {for (final k in wantLen.keys) k: 0};
    final bodies = {for (final k in wantLen.keys) k: <String>{}};
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        final want = wantLen[s.tag];
        if (want == null) continue;
        counts[s.tag] = counts[s.tag]! + 1;
        if (s.bytes.length == want) sized[s.tag] = sized[s.tag]! + 1;
        bodies[s.tag]!.add(s.bytes.map((x) => x.toRadixString(16)).join());
      }
    }
    for (final k in wantLen.keys) {
      expect(counts[k]!, greaterThan(0), reason: '$k absent from corpus');
      expect(sized[k]! / counts[k]!, greaterThan(0.99), reason: '$k not its fixed size in ${sized[k]}/${counts[k]}');
    }
    expect(bodies['RTSG']!.length / counts['RTSG']!, greaterThan(0.5), reason: 'RTSG should be per-VI varied');
    expect(bodies['OBSG']!.length / counts['OBSG']!, greaterThan(0.5), reason: 'OBSG should be per-VI varied');
    expect(bodies['CCSG']!.length, lessThan(50), reason: 'CCSG should be near-constant (shared signature)');
    expect(bodies['SCSR']!.length, lessThan(50), reason: 'SCSR should be near-constant');
  });

  test('VPDP/DLDR/GCPR are fixed-size, byte-constant records', () {
    final wantLen = <String, int>{'VPDP': 4, 'DLDR': 28, 'GCPR': 13};
    final counts = {for (final k in wantLen.keys) k: 0};
    final sized = {for (final k in wantLen.keys) k: 0};
    final bodies = {for (final k in wantLen.keys) k: <String>{}};
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        final want = wantLen[s.tag];
        if (want == null) continue;
        counts[s.tag] = counts[s.tag]! + 1;
        if (s.bytes.length == want) sized[s.tag] = sized[s.tag]! + 1;
        bodies[s.tag]!.add(s.bytes.map((x) => x.toRadixString(16)).join());
      }
    }
    for (final k in wantLen.keys) {
      expect(counts[k]!, greaterThan(0), reason: '$k absent');
      expect(sized[k]! / counts[k]!, greaterThan(0.99), reason: '$k not its fixed size (${sized[k]}/${counts[k]})');
      expect(bodies[k]!.length, lessThan(5), reason: '$k is no longer byte-constant (${bodies[k]!.length} distinct) — may be decodable now');
    }
  });

  test('NUID/SUID/BNID are [u32 count][count u32] id tables', () {
    var tot = 0, framed = 0;
    for (final f in all) {
      final List<ViSection> secs;
      try {
        secs = readViSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (!{'NUID', 'SUID', 'BNID'}.contains(s.tag) || s.bytes.length < 4) continue;
        tot++;
        final t = decodeIdTable(s.bytes);
        if (t != null && s.bytes.length == 4 + 4 * t.count && t.entries.length == t.count) framed++;
      }
    }
    expect(tot, greaterThan(0));
    expect(framed / tot, greaterThan(0.99), reason: 'id-table framing held for only $framed/$tot (<99%)');
  });
}
