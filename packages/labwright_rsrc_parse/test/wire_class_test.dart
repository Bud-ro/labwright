@Tags(['corpus'])
library;

import 'dart:io';

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

  test('endpoint terminal bounds: crc8 tunnels pin to their structure borders', () {
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    if (!crc8.existsSync()) return;
    final diagram = buildViModel(extractSnippetVi(crc8.readAsBytesSync())!).blockDiagrams.single;
    // endpoint oid -> absolute attach rect (t, l, b, r): the for-loop N terminal
    // (top-left corner), left-border tunnels of the outer and inner loops, the
    // case selector, and both shift registers — six distinct positions on the
    // outer loop (158,375..495,543), the inner loop, and the case frame.
    const wants = {
      88: (375, 158, 391, 174),
      98: (499, 158, 508, 167),
      179: (499, 263, 508, 272),
      223: (473, 341, 485, 349),
      2357: (403, 479, 415, 495),
      2360: (403, 158, 415, 174),
    };
    wants.forEach((oid, want) {
      final r = diagram.endpointTerminalBounds(oid)!;
      expect((r.top, r.left, r.bottom, r.right), want, reason: 'endpoint $oid');
    });
    expect(diagram.endpointTerminalBounds(904), isNull, reason: 'plain node endpoints carry no terminal record');
  });

  test('endpoint terminal bounds land on or inside their structure frame', () {
    var structFramed = 0, onOrInside = 0;
    for (final file in all.take(300)) {
      final ViModel model;
      try {
        model = buildViModel(file.readAsBytesSync());
      } catch (_) {
        continue;
      }
      // LabVIEW <= 8.5 heaps store termBounds (and bounds) in an absolute
      // space this decode does not cover — see ViDiagram.endpointTerminalBounds.
      if ((int.tryParse(model.version?.split('.').first ?? '') ?? 0) < 9) continue;
      for (final diagram in model.blockDiagrams) {
        for (final wire in diagram.wires) {
          for (final oid in wire.endpointOids) {
            final terminal = diagram.endpointTerminal(oid);
            if (terminal == null) continue;
            final frame = _boundedOwner(diagram, terminal.oid);
            if (frame == null || frame.objectClass.category != ViObjectKind.structure) continue;
            structFramed++;
            if (_onOrInsideFrame(diagram.endpointTerminalBounds(oid)!, frame.absBounds!)) onOrInside++;
          }
        }
      }
    }
    expect(structFramed, greaterThan(500), reason: 'sample should contain structure tunnels');
    expect(onOrInside, structFramed, reason: 'attach rects sit on/inside the frame ($onOrInside/$structFramed)');
  });
}

/// The nearest positional ancestor of [oid] (itself included) with bounds.
ViHeapObject? _boundedOwner(ViDiagram d, int oid) {
  var object = d.byId[oid];
  final seen = <int>{};
  while (object != null && seen.add(object.oid)) {
    if (object.absBounds != null) return object;
    object = object.parentOid == null ? null : d.byId[object.parentOid!];
  }
  return null;
}

/// Whether [pos] crosses [frame]'s border ring or lies fully within it.
bool _onOrInsideFrame(HeapRect pos, HeapRect frame) {
  bool spans(int line, int lo, int hi) => line >= lo && line <= hi;
  return spans(frame.left, pos.left, pos.right) ||
      spans(frame.right, pos.left, pos.right) ||
      spans(frame.top, pos.top, pos.bottom) ||
      spans(frame.bottom, pos.top, pos.bottom) ||
      (pos.left >= frame.left && pos.top >= frame.top && pos.right <= frame.right && pos.bottom <= frame.bottom);
}
