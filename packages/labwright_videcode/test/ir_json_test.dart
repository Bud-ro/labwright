@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

/// Tests for the JSON IR export ([viModelToJson]) — the serializable VI→IR→Dart
/// artifact. Three properties across the corpus:
///   (1) DETERMINISM — encoding the same VI twice yields byte-identical JSON;
///   (2) JSON-SAFETY — every VI's IR round-trips through jsonEncode/jsonDecode
///       (no non-finite numbers, no cycles, no non-encodable values);
///   (3) COVERAGE — every drawable diagram object (one with absolute bounds)
///       appears in the emitted node list (the IR loses no drawable object).
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
    test('IR JSON corpus tests (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('viModelToJson is deterministic and jsonEncode-safe for every VI', () {
    var files = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue; // malformed container — buildViModel throwing cleanly is fine
      }
      files++;
      final name = f.path.split('/').last;
      final a = jsonEncode(viModelToJson(model));
      // Build a SECOND model from an independent re-parse of the same bytes and
      // compare — this actually exercises determinism (object/dedup-list order
      // stability across parses), unlike encoding one model twice.
      final ViModel model2;
      try {
        model2 = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      final b = jsonEncode(viModelToJson(model2));
      if (a != b) {
        if (fails.length < 8) fails.add('NONDET $name');
        continue;
      }
      // jsonDecode must reproduce the structure (proves no lossy/non-encodable bits)
      final decoded = jsonDecode(a);
      if (decoded is! Map || decoded['irVersion'] != viIrVersion) {
        if (fails.length < 8) fails.add('BADROOT $name');
      }
    }
    expect(files, greaterThan(0));
    expect(fails, isEmpty, reason: 'IR JSON determinism/safety failures: $fails');
  });

  test('IR JSON represents every drawable object (no drawable lost)', () {
    var files = 0, diagrams = 0;
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
      for (final d in [...model.blockDiagrams, ...model.frontPanelDiagrams]) {
        diagrams++;
        final json = viDiagramToJson(d);
        final emitted = (json['objects'] as List)
            .map((o) => (o as Map)['oid'] as int)
            .toSet();
        // every object with absolute bounds (the drawable layer) must be present
        for (final o in d.nodes) {
          if (!emitted.contains(o.oid)) {
            if (fails.length < 8) fails.add('MISSING ${o.oid} in $name/${d.sectionTag}');
            break;
          }
        }
      }
    }
    expect(files, greaterThan(0));
    expect(diagrams, greaterThan(0));
    expect(fails, isEmpty, reason: 'IR JSON dropped drawable object(s): $fails');
  });

  test('VCTP type pool recovers a type inventory for the vast majority of VIs', () {
    var files = 0, withTypes = 0, totalTypes = 0, totalUnknown = 0;
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      if (model.types.isNotEmpty) withTypes++;
      totalTypes += model.types.length;
      totalUnknown += model.types.where((t) => t.kind == ViDataType.unknown).length;
    }
    expect(files, greaterThan(0));
    expect(totalTypes, greaterThan(0));
    // ratchet: VCTP is present + parseable for ~99.6% of VIs — floor at 90%.
    expect(withTypes, greaterThan((files * 0.90).floor()),
        reason: 'type-pool recovery dropped: only $withTypes/$files VIs yielded types');
    // sanity: the catalogue covers a real majority of descriptors (not all-unknown).
    expect(totalUnknown, lessThan(totalTypes * 0.6),
        reason: 'too many uncatalogued type codes: $totalUnknown/$totalTypes');
  });
}
