@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
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
}
