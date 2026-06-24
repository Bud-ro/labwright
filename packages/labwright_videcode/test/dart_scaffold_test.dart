@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

/// Tests for the honest IR->Dart structural scaffold ([generateDartScaffold]).
/// Across the corpus:
///   (1) DETERMINISM — same VI yields an identical scaffold string;
///   (2) HONEST MARKER — every scaffold carries the no-dataflow disclaimer
///       ([scaffoldMarker]) so generated stubs can never masquerade as logic;
///   (3) COVERAGE RATCHET — every block-diagram structure and node appears in
///       the output (by its `[oid N]` marker); the scaffold drops no logic
///       element, even if it can't recover the wiring between them.
void main() {
  List<File> vis(String root) {
    final d = Directory(root);
    if (!d.existsSync()) return const [];
    return d
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.vi'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  final all = [...vis('/tmp/claude-1000/vi_samples'), ...vis('/tmp/claude-1000/vi_diverse')];
  if (all.isEmpty) {
    test('Dart scaffold corpus tests (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('generateDartScaffold is deterministic and always carries the honest marker', () {
    var files = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      final name = f.path.split('/').last;
      final a = generateDartScaffold(model);
      final b = generateDartScaffold(model);
      if (a != b) {
        if (fails.length < 8) fails.add('NONDET $name');
        continue;
      }
      if (!a.contains(scaffoldMarker)) {
        if (fails.length < 8) fails.add('NOMARKER $name');
      }
    }
    expect(files, greaterThan(0));
    expect(fails, isEmpty, reason: 'scaffold determinism/marker failures: $fails');
  });

  test('scaffold represents every block-diagram structure and node (no logic dropped)', () {
    var files = 0, checked = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      final name = f.path.split('/').last;
      final out = generateDartScaffold(model);
      // the scaffold emits every non-empty block diagram; gather every struct/node
      // oid it is therefore obligated to represent.
      for (final d in model.blockDiagrams) {
        final logic = d.objects.where(
            (o) => o.category == ViObjectKind.structure || o.category == ViObjectKind.node);
        if (logic.isEmpty) continue;
        for (final o in logic) {
          checked++;
          if (!out.contains('[oid ${o.oid}]')) {
            if (fails.length < 8) fails.add('MISSING oid ${o.oid} (${o.category.name}) in $name/${d.sectionTag}');
            break;
          }
        }
      }
    }
    expect(files, greaterThan(0));
    expect(checked, greaterThan(0));
    expect(fails, isEmpty, reason: 'scaffold dropped logic element(s): $fails');
  });
}
