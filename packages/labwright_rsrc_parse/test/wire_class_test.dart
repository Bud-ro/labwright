@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The `0x1d` wire-segment class ([HeapObjectClass.bdWire]) is BD-only and its own-level rect is a
/// degenerate (line-like) Manhattan run. Samples a corpus slice per run to stay fast.
void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('wire class invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('0x1d objects are BD-only wire segments with line-like bounds', () {
    var bdWires = 0, fpWires = 0, withBounds = 0, lineLike = 0;
    for (final file in all.take(300)) {
      final ViModel model;
      try {
        model = buildViModel(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final object in model.blockDiagrams.expand((d) => d.objects)) {
        if (object.kind != 0x1d) continue;
        bdWires++;
        expect(object.category, ViObjectKind.wire);
        final bounds = object.bounds;
        if (bounds == null) continue;
        withBounds++;
        if (bounds.top == bounds.bottom || bounds.left == bounds.right) lineLike++;
      }
      for (final object in model.frontPanelDiagrams.expand((d) => d.objects)) {
        if (object.kind == 0x1d) fpWires++;
      }
    }
    expect(bdWires, greaterThan(100), reason: 'sample should contain wires');
    expect(fpWires, 0, reason: 'wires are a BD-only class (0 FP at discovery)');
    expect(lineLike, withBounds, reason: 'every wire rect is a degenerate Manhattan run ($lineLike/$withBounds)');
  });
}
