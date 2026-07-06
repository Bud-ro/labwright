@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Corpus invariants for the `0x1d` wire-segment class (see
/// [HeapObjectClass.bdWire]): wire objects are BD-only, and the rect record a
/// wire carries at its own level is a degenerate (line-like) Manhattan run.
/// Measured at discovery over the whole corpus: 61673 BD / 0 FP, 61396/61396
/// line-like. This test samples a slice per run to stay fast.
void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('wire class invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('0x1d objects are BD-only wire segments with line-like bounds', () {
    var bdWires = 0;
    var fpWires = 0;
    var withBounds = 0;
    var lineLike = 0;
    for (final file in all.take(300)) {
      final ViModel model;
      try {
        model = buildViModel(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final diagram in model.blockDiagrams) {
        for (final object in diagram.objects) {
          if (object.kind != 0x1d) continue;
          bdWires++;
          expect(object.category, ViObjectKind.wire);
          final bounds = object.bounds;
          if (bounds == null) continue;
          withBounds++;
          if (bounds.top == bounds.bottom || bounds.left == bounds.right) lineLike++;
        }
      }
      for (final diagram in model.frontPanelDiagrams) {
        for (final object in diagram.objects) {
          if (object.kind == 0x1d) fpWires++;
        }
      }
    }
    expect(bdWires, greaterThan(100), reason: 'sample should contain wires');
    expect(fpWires, 0, reason: 'wires are a BD-only class (0 FP at discovery)');
    expect(
      lineLike,
      withBounds,
      reason:
          'every wire bounds rect is a degenerate Manhattan run '
          '($lineLike/$withBounds)',
    );
    // ignore: avoid_print
    print('wire sample: $bdWires BD wires, $withBounds with bounds, all line-like');
  });
}
