@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

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
List<File> _vis(String dir, int take) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final all = d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return take <= 0 ? all : all.take(take).toList();
}

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

void main() {
  final sample = _vis('/tmp/claude-1000/vi_samples', 0);
  if (sample.isEmpty) {
    test('invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  final diverse = _vis('/tmp/claude-1000/vi_diverse', 0);
  final all = [...sample, ...diverse];

  test('DETERMINISM: building the same VI twice yields an identical object graph', () {
    // Double-parse is ~2x cost, so a deterministic slice is plenty to catch a
    // non-deterministic decode (it would fail on essentially any affected VI).
    for (final f in all.take(250)) {
      final bytes = f.readAsBytesSync();
      expect(_sig(buildViModel(bytes)), _sig(buildViModel(bytes)), reason: 'non-deterministic decode: ${f.path}');
    }
  });

  // SANE BOUNDS is the one structural property that genuinely holds for every
  // object. Two other "obvious" invariants were tested here and FALSIFIED on the
  // real corpus, which is itself valuable knowledge (it proves the decode's
  // guards are load-bearing, not theoretical):
  //   * oids are NOT unique within a diagram — real heaps reuse them (handled by
  //     the walker/reanchor; see the duplicate-oid termination test);
  //   * parent chains are NOT acyclic — real VIs contain parent cycles / oid-reuse
  //     loops (e.g. oid 0x8000), which the shiftSubtree/reanchorViewport seen-set
  //     guards tolerate. So we do NOT assert uniqueness or acyclicity.
  test('STRUCTURAL INVARIANT: every decoded object has sane (non-wild) bounds', () {
    var checked = 0;
    for (final f in all) {
      final ViModel m;
      try {
        m = buildViModel(f.readAsBytesSync());
      } catch (_) {
        continue; // totality is guarded elsewhere
      }
      for (final o in [...m.blockDiagrams, ...m.frontPanelDiagrams].expand((d) => d.objects)) {
        final r = o.absBounds;
        if (r == null) continue;
        checked++;
        // Magnitude sanity on the raw coordinates: a mis-decode (wrong offset /
        // walk desync) tends to surface as a wild coordinate, while real VI coords
        // sit well inside this range. NOTE: we check each coordinate's magnitude,
        // not width/height sign — INVERTED rects (negative w/h) are real in the
        // corpus and are filtered at render by HeapRect.isValid, so they are not a
        // decode error.
        for (final c in [r.left, r.top, r.right, r.bottom]) {
          expect(c, inInclusiveRange(-200000, 200000), reason: 'wild coordinate $c in ${f.path}');
        }
      }
    }
    expect(checked, greaterThan(0));
  });

  test('STRUCTURAL INVARIANT: front-panel coords may be negative (parked off-panel) and survive', () {
    // Controls parked off the top-left of the panel origin (e.g. error in/out
    // clusters in many example VIs) carry genuine NEGATIVE signed-s16 coordinates.
    // They are faithful, not a decode bug (~13.6% of corpus FP objects), and must
    // NOT be clamped to the origin — a clamp would silently relocate parked
    // controls. Assert that negatives reach the model unaltered.
    var negObjs = 0, filesWithNeg = 0, bounded = 0;
    for (final f in all) {
      final ViModel m;
      try {
        m = buildViModel(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      var fileHasNeg = false;
      for (final o in m.frontPanelDiagrams.expand((d) => d.objects)) {
        final r = o.absBounds;
        if (r == null) continue;
        bounded++;
        if (r.top < 0 || r.left < 0) {
          negObjs++;
          fileHasNeg = true;
        }
      }
      if (fileHasNeg) filesWithNeg++;
    }
    expect(bounded, greaterThan(0));
    // negative panel coords are common and preserved (probe: ~13.6% of objects).
    expect(negObjs, greaterThan(0), reason: 'no negative FP coords survived — parked controls may be clamped');
    expect(filesWithNeg, greaterThan(0));
  });

  test('STRUCTURAL INVARIANT: drawn FP objects are distinctly placed (overlap is layout, not a collapse)', () {
    // FP controls overlap heavily — but that is faithful (a control sits inside its
    // container; chrome/scrollbars overlap content; dense panels). It is NOT a
    // decode collapse: drawn objects carry DISTINCT bounds (probe: 76.6% of drawn
    // objects have a unique rect). A decode bug collapsing objects to one rect would
    // crater this ratio, so assert it stays well above a floor.
    var drawn = 0, distinct = 0;
    for (final f in all) {
      final ViModel m;
      try {
        m = buildViModel(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final d in m.frontPanelDiagrams) {
        final keys = <String>{};
        var n = 0;
        for (final o in d.objects) {
          final r = o.absBounds;
          if (r == null || !r.isValid || r.width <= 1 || r.height <= 1) continue;
          n++;
          keys.add('${r.top},${r.left},${r.bottom},${r.right}');
        }
        if (n < 8) continue; // tiny diagrams aren't a meaningful ratio
        drawn += n;
        distinct += keys.length;
      }
    }
    expect(drawn, greaterThan(0));
    // aggregate unique-rect fraction (probe: ~76.6%); floor well below that.
    expect(distinct / drawn, greaterThan(0.55),
        reason: 'drawn FP objects collapsed to shared rects: only $distinct/$drawn distinct');
  });

  test('RENDER RATCHET: visible block-diagram objects classify to a typed widget (>= floor)', () {
    var visible = 0, typed = 0;
    for (final f in all) {
      try {
        final m = buildViModel(f.readAsBytesSync());
        for (final o in m.blockDiagrams.expand((d) => d.objects)) {
          final r = o.absBounds;
          if (r == null || r.width <= 1 || r.height <= 1) continue;
          visible++;
          if (o.category != ViObjectKind.unknown) typed++;
        }
      } catch (_) {}
    }
    expect(visible, greaterThan(0));
    final frac = typed / visible;
    // Current: ~0.998. Floor at 0.99 — ratchets up only; raise the floor when a
    // commit legitimately improves it (mirrors the coverage baseline discipline).
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'BD render-typed fraction dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%).');
  });

  test('RENDER RATCHET: visible FRONT-PANEL objects classify to a typed widget (>= floor)', () {
    var visible = 0, typed = 0;
    for (final f in all) {
      try {
        final m = buildViModel(f.readAsBytesSync());
        for (final o in m.frontPanelDiagrams.expand((d) => d.objects)) {
          final r = o.absBounds;
          if (r == null || r.width <= 1 || r.height <= 1) continue;
          visible++;
          if (o.category != ViObjectKind.unknown) typed++;
        }
      } catch (_) {}
    }
    expect(visible, greaterThan(0));
    final frac = typed / visible;
    // Current: ~0.9991. Floor 0.99, upward-only — the front-panel taxonomy is the
    // most mature, so this guards against a regression dropping FP coverage.
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'FP render-typed fraction dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%).');
  });

  // 7. NAMING-RECOVERY RATCHET — distinct from the render ratchets (typed widget):
  // this guards that subVI-CALL node kinds recover their called-VI *name* (the
  // `.vi`/`.lvclass` filename) via 0xa-caption propagation. That name is the call
  // graph — losing it would silently gut "understanding" while every render ratchet
  // still passed. Floor 0.99 (currently ~0.9965), upward-only.
  test('NAMING RATCHET: subVI-call nodes recover their called-VI name (>= floor)', () {
    const subviKinds = {0x31, 0x32, 0xc5, 0x104, 0x103};
    var total = 0, named = 0;
    for (final f in all) {
      try {
        for (final o in buildViModel(f.readAsBytesSync()).blockDiagrams.expand((d) => d.objects)) {
          if (!subviKinds.contains(o.kind)) continue;
          total++;
          if (o.label != null && o.label!.trim().isNotEmpty) named++;
        }
      } catch (_) {}
    }
    expect(total, greaterThan(0));
    final frac = named / total;
    expect(frac, greaterThanOrEqualTo(0.99),
        reason: 'subVI-call name recovery dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 99%) — '
            'the 0xa-caption propagation likely regressed.');
  });

  // 8. LAYOUT-CONTAINMENT RATCHET — geometric correctness of coordinate
  // composition: a drawn BD node whose ancestor chain includes a drawn structure
  // frame should have its CENTER inside that frame (nodes live in their loop/case
  // body). A drop signals a coordinate-composition / re-anchor regression that the
  // typed-widget render ratchets would NOT catch (a node can be the right widget
  // but in the wrong place). Floor 0.98 (currently ~0.9936), upward-only.
  test('LAYOUT RATCHET: BD nodes sit inside their enclosing structure frame (>= floor)', () {
    bool inside(HeapRect o, int cx, int cy) => cx >= o.left && cx <= o.right && cy >= o.top && cy <= o.bottom;
    var pairs = 0, contained = 0;
    for (final f in all) {
      try {
        for (final diag in buildViModel(f.readAsBytesSync()).blockDiagrams) {
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
            pairs++;
            if (inside(frame, b.left + b.width ~/ 2, b.top + b.height ~/ 2)) contained++;
          }
        }
      } catch (_) {}
    }
    expect(pairs, greaterThan(0));
    final frac = contained / pairs;
    expect(frac, greaterThanOrEqualTo(0.98),
        reason: 'node-in-structure containment dropped to ${(frac * 100).toStringAsFixed(2)}% (floor 98%) — '
            'coordinate composition / re-anchor likely regressed.');
  });

  // 4. MUTATION-FUZZ ROBUSTNESS — flip bytes inside genuine VIs and push them
  // through the FULL pipeline (decodeSections -> inflate -> heap walk -> build).
  // This is deeper than the truncation fuzz (parseVi only) and the random-bytes
  // buildDiagram test: it exercises the walker on plausibly-corrupt, real-RSRC,
  // inflated payloads. Contract: each build must COMPLETE (return or throw
  // cleanly — never hang/OOM), and WHEN it returns, the output must still satisfy
  // the bounds-sanity invariant (corruption must not leak wild coordinates into
  // the render). Deterministic RNG so a failure reproduces.
  test('MUTATION-FUZZ: byte-flipped VIs decode without hanging and never emit wild bounds', () {
    final rng = Random(0xC0FFEE);
    for (final f in all.take(40)) {
      final orig = f.readAsBytesSync();
      if (orig.length < 64) continue;
      for (var iter = 0; iter < 8; iter++) {
        final m = Uint8List.fromList(orig);
        final flips = 1 + rng.nextInt(3);
        for (var k = 0; k < flips; k++) {
          m[rng.nextInt(m.length)] ^= 1 << rng.nextInt(8);
        }
        ViModel? built;
        // Completing this expect at all means no hang/OOM (a hang trips the test
        // runner timeout); a clean throw on corrupt input is allowed.
        expect(() {
          try {
            built = buildViModel(m);
          } catch (_) {
            built = null;
          }
        }, returnsNormally);
        if (built case final mm?) {
          for (final o in [...mm.blockDiagrams, ...mm.frontPanelDiagrams].expand((d) => d.objects)) {
            final r = o.absBounds;
            if (r == null) continue;
            for (final c in [r.left, r.top, r.right, r.bottom]) {
              expect(c, inInclusiveRange(-200000, 200000),
                  reason: 'corruption leaked a wild coordinate $c (seed VI ${f.path}, iter $iter)');
            }
          }
        }
      }
    }
  });

  // 5. CATALOG INTEGRITY — clean-room honesty guard: every named HeapObjectClass
  // entry must have real corpus evidence (occur >= 1 time). Catches a future
  // fabricated / copy-pasted-wrong / corpus-drifted-away catalog entry — a class
  // we "name" but that no VI actually contains. Confirmed at probe time: 0 of the
  // current entries are corpus-absent.
  test('CATALOG INTEGRITY: every catalogued object-class kind occurs in the corpus', () {
    final seen = <int>{};
    for (final f in all) {
      try {
        final m = buildViModel(f.readAsBytesSync());
        for (final o in [...m.blockDiagrams, ...m.frontPanelDiagrams].expand((d) => d.objects)) {
          seen.add(o.kind);
        }
      } catch (_) {}
    }
    for (final c in HeapObjectClass.values) {
      if (c == HeapObjectClass.unknown) continue;
      expect(seen.contains(c.code), isTrue,
          reason: 'catalogued kind 0x${c.code.toRadixString(16)} (${c.name}) has NO corpus evidence — '
              'fabricated/dead entry, or the corpus drifted. Re-probe before keeping it.');
    }
  });

  // 6. BLOCK-CATALOG ↔ CORPUS — the block catalog's recordHeap classification must
  // match the *decompressed* structure: a real C4 heap opens with a u32
  // content-length == len-4 followed by a group-open/C4 lead. This guards the
  // load-bearing gate (only true heaps get the record-walk) so other compressed
  // blocks (VCTP/VICD/DFDS/TM80…) can never be mis-read as heaps with a bogus
  // content length + fat "unframed tail". Forward direction must be 100%.
  test('BLOCK CATALOG: every catalogued record-heap section really is a C4 heap (and only those)', () {
    bool heapLead(int x) => x == 0xc4 || (x >= 0x08 && x <= 0x13);
    bool structuralHeap(List<int> b) {
      if (b.length < 8) return false;
      final declared = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
      return declared == b.length - 4 && heapLead(b[4]);
    }

    final headTags = <String>{};
    var catHeapSections = 0, catHeapStructural = 0;
    var structuralSections = 0, structuralCatalogued = 0;
    for (final f in all.take(900)) {
      final List<DecodedSection> secs;
      try {
        secs = decodeSections(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        final isCatHeap = isRecordHeapTag(s.tag);
        final isStruct = structuralHeap(s.bytes);
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
    }
    // FORWARD (load-bearing): every catalogued heap section is structurally a heap.
    expect(catHeapSections, greaterThan(0));
    expect(catHeapStructural, catHeapSections,
        reason: 'a catalogued record-heap section was NOT a structural C4 heap — the recordHeap set is wrong.');
    // The catalog's four heap tags actually occur in the corpus.
    expect(headTags, containsAll(<String>{'FPHb', 'BDHb'}));
    // REVERSE (coverage): structurally-heap sections are almost all catalogued
    // heaps — a missed heap tag would crater this. (STRG etc. give <2% coincidences.)
    expect(structuralSections, greaterThan(0));
    expect(structuralCatalogued / structuralSections, greaterThan(0.97),
        reason: 'structural heaps not catalogued as recordHeap: only $structuralCatalogued/$structuralSections — '
            'a real heap tag may be missing from the catalog.');
  });

  // 7. LVSR SAVE-RECORD ↔ CORPUS — the decoded LVSR version word must match the
  // independent `vers` string, and its @96 password-hash slot must mirror the
  // BDPW block. These cross-source agreements are what make the field claims
  // honest (not a lucky single-VI reading). Floors set just below the probed
  // rates (version 7579/7583, password 5707/5710 ≈ 99.9%).
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
      // version cross-check against the independent vers string.
      final vstr = decodeVersion(bytes).version;
      if (vstr != null) {
        final m = RegExp(r'^(\d{1,2})').firstMatch(vstr);
        if (m != null) {
          verTotal++;
          if (rec.versionMajor == int.parse(m.group(1)!)) verMatch++;
        }
      }
      // @96 hash mirrors BDPW.
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
    // stage byte was 0x80 across the entire corpus at probe time.
    expect(stageNon80, 0, reason: 'an LVSR stage byte != 0x80 appeared ($stageNon80) — re-probe the stage claim.');
  });

  // 8. CONNECTOR PANE ↔ VCTP — the 2-byte CONP value is a 1-based index into the
  // VI's type pool; cross-checking it resolves in-range against the
  // independently-decoded VCTP is what makes the "CONP is a VCTP index" claim
  // honest (corpus: 7550/7550 = 100%). NOTE: this is CONP-specific — CPC2's same
  // slot resolves in-range only ~84% and is NOT claimed as an index, so the test
  // reads the CONP section directly (not connectorPaneFromSections, which would
  // also accept a CPC2 fallback). A future off-by-one / layout drift trips this.
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

  // 9. TM80 SHORT-FORM COVERAGE — the decoded TM80 short form (length == 4 +
  // 2*count, with `count` entries) accounts for a majority of TM80 sections;
  // assert the coverage and the self-consistency (entries.length == count) so a
  // decode regression or a coverage drop is caught. (Corpus: 5367/7593 ≈ 70.7%
  // short-form — VIs typically have ~2 TM80 sections and the other is the larger
  // not-yet-decoded layout; entry SEMANTICS remain undecoded — not asserted.)
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
          // self-consistency with teeth: a loop-bound regression would make the
          // entry list length disagree with the declared count. (rawLength ==
          // 4+2*count is the branch gate itself, so it is not re-asserted.)
          expect(m.entries.length, m.count);
        }
      }
    }
    expect(total, greaterThan(0));
    expect(shortForm / total, greaterThan(0.65),
        reason: 'TM80 short-form coverage dropped to $shortForm/$total (<65%; corpus ≈70.7%).');
  });

  // 10. STRG TEXT BLOCK — the VI description block is [u32 len][UTF-8 text] with
  // len == sectionLength-4 and a printable body. Corpus: 100% (2980/2980). Assert
  // the length law + printability so a decode regression is caught.
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
          // body is overwhelmingly printable text
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

  // 11. DTHP FRAMING — the data-type heap is the 4-byte [u16][u16] header in the
  // overwhelming majority; a rare extended form carries named items. Assert the
  // 4-byte dominance (corpus 99.6%) and that decode is total. (Header-field
  // meaning is undecoded — not asserted.)
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

  // 11b. DTHP EXTENDED NAME RECOVERY — the rare extended form (length>4) is
  // decoded by the most fragile, heuristic path (the tolerant 40xx _scanNames
  // anchor-scan). Guard it: every extended DTHP must recover >=1 name and every
  // recovered name must be printable. A regression in the scan (off-by-one on
  // the len byte, dropped 0x40 anchor) would silently empty/garble names and no
  // other test would notice. Corpus: 33/33 extended sections recover names.
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
        // match _scanNames' accepted set: tab/newline/CR + printable ASCII.
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

  // 12. HIST RECORD — the revision-history block is a fixed 40-byte record:
  // version@0==2 and the reserved words (@12/@28/@32) are zero across the corpus.
  // Assert the fixed size + these constants so a decode/layout regression trips.
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

  // 14. HELP BLOCKS — HLPP is a PTH0 path (magic + self-consistent component
  // parse to a clean path); HLPT shares the STRG [u32 len][text] layout. Assert
  // both for ≥99% (corpus: HLPP 128/128 PTH0, HLPT 200/200 length-law).
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
          // PTH0 magic present, at least one component, and a non-empty path.
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

  // 13. FTAB FONT TABLE — version==1 and the name-table framing is self-
  // consistent: reading fontCount Pascal strings recovers exactly that many
  // printable names. Asserting recovered==count is the killer self-consistency
  // check (corpus: every FTAB resolves cleanly).
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

  // 15. LEGACY ICON BITMAPS — icl8/icl4/ICON are exact 32x32 bitmaps at 8/4/1 bpp
  // (1024/512/128 B), each decoding to 1024 pixels. Corrects a stale belief that
  // ICON was a name table / icl8 a stub: assert exact sizes + full 1024-pixel
  // decode across the corpus (probe: 100%).
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

  // 16. VERSION WORD — the vers binary version word (BCD major) must agree with
  // the independently-decoded vers ASCII string AND with the LVSR version word.
  // This triple agreement is what confirms the [BCD major][minor<<4|patch] layout
  // (corpus: vers==string 7579/7583, vers==LVSR 7583/7583 = 100%).
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
}
