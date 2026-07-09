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

  test('signal (0x17) wires carry resolvable oid endpoints + anchors, no bounds', () {
    var signals = 0, fpSignals = 0, endpoints = 0, anchorsResolved = 0, twoEndpoints = 0, withOwnBounds = 0;
    var wireObjects = 0;
    for (final file in all.take(300)) {
      final ViModel model;
      try {
        model = buildViModel(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      for (final diagram in model.blockDiagrams) {
        for (final object in diagram.objects) {
          if (object.kind != 0x17) continue;
          // A signal is classified as a wire and carries no bounds of its own.
          expect(object.category, ViObjectKind.wire);
          if (object.absBounds != null) withOwnBounds++;
        }
        for (final wire in diagram.wires) {
          signals++;
          expect(
            wire.endpointOids.length,
            diagram.byId[wire.signalOid]!.refs.length,
            reason: 'endpoints are the signal\'s 14 19 childRefs',
          );
          expect(wire.endpointAnchors.length, wire.endpointOids.length, reason: 'anchors index-align endpoints');
          endpoints += wire.endpointOids.length;
          if (wire.endpointOids.length == 2) twoEndpoints++;
          for (final anchor in wire.endpointAnchors) {
            if (anchor != null) anchorsResolved++;
          }
        }
        wireObjects += diagram.wires.length;
      }
      for (final object in model.frontPanelDiagrams.expand((d) => d.objects)) {
        if (object.kind == 0x17) fpSignals++;
      }
    }
    expect(signals, greaterThan(100), reason: 'sample should contain signal wires');
    expect(wireObjects, signals, reason: 'one ViWire per signal object');
    expect(fpSignals, 0, reason: 'signals are a BD-only class (0 FP)');
    expect(withOwnBounds, 0, reason: 'signals carry no bounds of their own');
    // Corpus-wide the 14 19 childRefs resolve 100% to a bounded owner.
    expect(anchorsResolved, endpoints, reason: 'every endpoint resolves to an anchor ($anchorsResolved/$endpoints)');
    // 91% of signals hold exactly two endpoints (source + sink).
    expect(twoEndpoints, greaterThan(signals * 0.7), reason: 'most wires are two-endpoint ($twoEndpoints/$signals)');
  });
}
