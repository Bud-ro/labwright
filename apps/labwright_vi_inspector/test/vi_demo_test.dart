import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';
import 'package:labwright_rsrc_parse/testing.dart';

void main() {
  test('minimalViBytes parses into a VI with the expected capabilities', () {
    final load = summarize(minimalViBytes());
    expect(load.isOk, isTrue);
    final vi = load.summary!;
    expect(vi.name, 'demo.vi');
    expect(vi.isVi, isTrue);
    expect(vi.hasBlockDiagram, isTrue);
    expect(vi.hasFrontPanel, isTrue);
    expect(vi.hasConnectorPane, isTrue);
    expect(vi.hasSubViLinks, isTrue);
    expect(vi.blocks, containsAll(<String>['BDHb', 'FPHb', 'CONP', 'LIvi']));
  });

  test('summarize reports a friendly error on non-VI bytes (never throws)', () {
    final load = summarize(Uint8List.fromList(List.filled(64, 0)));
    expect(load.isOk, isFalse);
    expect(load.error, isNotNull);
  });

  test(
    'summarize is total over arbitrary junk — the importer never throws',
    () {
      final rng = Random(2);
      for (var i = 0; i < 5000; i++) {
        final n = rng.nextInt(1024);
        final b = Uint8List.fromList([
          for (var j = 0; j < n; j++) rng.nextInt(256),
        ]);
        final load = summarize(b);
        expect(load.isOk || load.error != null, isTrue);
      }
    },
  );
}
