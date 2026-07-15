@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the growable-prim decode ([GrowablePrim] /
/// [growablePrimVariantKey]) — the structure the catalog's doc comments
/// cite, recomputed from scratch and pinned against the `growable_prims`
/// snapshot section.
///
/// Per class (keys use the class code in hex):
///  * `n<c>` — node count across every block-diagram heap.
///  * `wrap<c>` — `0x15` terminal wrappers under those nodes.
///  * `dco<c>` — wrappers holding the class-paired DCO ([GrowablePrim
///    .dcoClassCode]).
///  * `out<c>` — paired DCOs with [kGrowableDcoOutputFlag] set.
///  * `mode<c>` — paired DCOs with [kGrowableRowModeFlag] set.
///  * `foreign` — wrapper children of any non-paired object kind
///    (law: none exist).
///  * `cpdMode<m>` — Compound Arithmetic nodes per decoded mode field.
///
/// Laws asserted structurally (not snapshotted):
///  * every wrapper child is the paired DCO — `foreign == 0`;
///  * DCO-less wrappers exist only on Bundle, exactly one per node (the
///    cluster-passthrough slot);
///  * single-output classes (Build Array, Bundle, Concatenate Strings,
///    Compound Arithmetic, Array Subset, Replace Array Subset,
///    Initialize Array, Merge Errors) measure `out == n` exactly;
///    Format Into String and Delete From Array measure `out == 2n`;
///    Unbundle measures `out == wrap − n` (all rows but the input);
///  * [growablePrimVariantKey]'s `o` chars re-derive `out` exactly (the
///    key is the flag decode, so the two can never drift apart).
Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final ViModel model;
  try {
    model = buildViModelFromDecoded(decodeSections(bytes));
  } catch (_) {
    return c;
  }
  for (final d in model.blockDiagrams) {
    for (final o in d.objects) {
      final prim = GrowablePrim.fromClassCode(o.kind);
      if (prim == null) continue;
      final code = o.kind.toRadixString(16);
      bump('n$code');
      final key = growablePrimVariantKey(d, o)!;
      var keyOutputs = 0;
      for (final ch in key.codeUnits) {
        if (ch == 0x6f /* o */ ) keyOutputs++;
      }
      var outputs = 0;
      for (final wrapper in d.children(o.oid)) {
        if (wrapper.kind != 0x15) continue;
        bump('wrap$code');
        for (final child in d.children(wrapper.oid)) {
          if (child.kind != prim.dcoClassCode) {
            bump('foreign');
            continue;
          }
          bump('dco$code');
          final flags = child.objFlags ?? 0;
          if ((flags & kGrowableDcoOutputFlag) != 0) {
            bump('out$code');
            outputs++;
          }
          if ((flags & kGrowableRowModeFlag) != 0) bump('mode$code');
        }
      }
      if (keyOutputs != outputs) bump('keyOutputMismatch');
      if (prim == GrowablePrim.compoundArithmetic) {
        final mode = ((o.objFlags ?? 0) >> kCompoundArithModeShift) & kCompoundArithModeMask;
        bump('cpdMode$mode');
      }
    }
  }
  return c;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('growable-prim census (skipped: corpus not fetched)', () {
      markTestSkipped('corpus not fetched');
    }, skip: true);
    return;
  }

  late final Map<String, int> C;
  setUpAll(() async {
    final res = await corpusParallel(all, _census);
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  int n(String k) => C[k] ?? 0;

  test('every 0x15 wrapper holds only the class-paired DCO', () {
    expect(n('foreign'), 0);
  });

  test('DCO-less wrappers are exactly Bundle\'s passthrough slot', () {
    for (final p in GrowablePrim.values) {
      final code = p.classCode.toRadixString(16);
      final placeholders = n('wrap$code') - n('dco$code');
      expect(
        placeholders,
        p == GrowablePrim.bundle ? n('n$code') : 0,
        reason: '${p.opName} (0x$code) placeholder wrappers',
      );
    }
  });

  test('output-direction bit counts follow each operation\'s shape', () {
    const oneOutput = {
      GrowablePrim.bundle,
      GrowablePrim.buildArray,
      GrowablePrim.concatenateStrings,
      GrowablePrim.arraySubset,
      GrowablePrim.compoundArithmetic,
      GrowablePrim.replaceArraySubset,
      GrowablePrim.initializeArray,
      GrowablePrim.mergeErrors,
    };
    const twoOutputs = {
      GrowablePrim.formatIntoString,
      GrowablePrim.deleteFromArray,
    };
    for (final p in GrowablePrim.values) {
      final code = p.classCode.toRadixString(16);
      final expected = oneOutput.contains(p)
          ? n('n$code')
          : twoOutputs.contains(p)
          ? 2 * n('n$code')
          : p == GrowablePrim.unbundle
          ? n('wrap$code') - n('n$code')
          : null; // Index Array: one output per row group, no fixed law.
      if (expected == null) continue;
      expect(n('out$code'), expected, reason: '${p.opName} (0x$code) outputs');
    }
  });

  test('variant keys re-derive the output decode exactly', () {
    expect(n('keyOutputMismatch'), 0);
  });

  test('growable-prim census matches the committed snapshot exactly', () {
    expectCorpusSnapshot('growable_prims', C);
  });
}
