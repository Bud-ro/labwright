@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_vi_parse/labwright_vi_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

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

  final all = [...vis(corpusSampleDir.path), ...vis(corpusDiverseDir.path)];
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
      if (decoded is! Map || !decoded.containsKey('blockDiagrams')) {
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

  test('VCTP named typedefs are recovered and look like real identifiers', () {
    var files = 0, vIsWithNames = 0, totalNames = 0;
    final badNames = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      final named = namedTypes(model.types);
      if (named.isNotEmpty) vIsWithNames++;
      totalNames += named.length;
      for (final t in named) {
        final n = t.name!;
        // recovered names must be non-empty, printable, and contain a letter
        if (n.isEmpty || n.runes.any((c) => c < 0x20 || c >= 0x7f) || !RegExp(r'[A-Za-z]').hasMatch(n)) {
          if (badNames.length < 8) badNames.add('"$n" in ${f.path.split('/').last}');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(totalNames, greaterThan(0));
    expect(badNames, isEmpty, reason: 'malformed recovered type names: $badNames');
    // ratchet: named typedefs are common (probe ~most VIs); floor at 40% of VIs.
    expect(vIsWithNames, greaterThan((files * 0.40).floor()),
        reason: 'named-type recovery dropped: only $vIsWithNames/$files VIs yielded names');
  });

  test('cluster member structures resolve into valid fields', () {
    var files = 0, clusters = 0, clustersWithMembers = 0, totalFields = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      for (final t in model.types) {
        if (t.kind != ViDataType.cluster) continue;
        clusters++;
        if (t.members.isEmpty) continue;
        clustersWithMembers++;
        // every declared member index must be in range
        for (final i in t.members) {
          if (i < 0 || i >= model.types.length) {
            if (fails.length < 8) fails.add('OOB member $i in ${f.path.split('/').last}');
          }
        }
        totalFields += clusterFields(t, model.types).length;
      }
    }
    expect(files, greaterThan(0));
    expect(clusters, greaterThan(0));
    expect(fails, isEmpty, reason: 'cluster members out of range: $fails');
    expect(totalFields, greaterThan(0));
    // ratchet: most clusters expose a parseable member list (probe ~99.9%).
    expect(clustersWithMembers, greaterThan((clusters * 0.80).floor()),
        reason: 'cluster member recovery dropped: $clustersWithMembers/$clusters');
  });

  test('array element types resolve into valid in-range indices', () {
    var files = 0, arrays = 0, arraysWithElem = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      for (final t in model.types) {
        if (t.kind != ViDataType.array) continue;
        arrays++;
        if (t.elementIndex == null) continue;
        arraysWithElem++;
        if (t.elementIndex! < 0 || t.elementIndex! >= model.types.length) {
          if (fails.length < 8) fails.add('OOB elem ${t.elementIndex} in ${f.path.split('/').last}');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(arrays, greaterThan(0));
    expect(fails, isEmpty, reason: 'array element index out of range: $fails');
    // ratchet: most arrays expose a parseable element type.
    expect(arraysWithElem, greaterThan((arrays * 0.80).floor()),
        reason: 'array element recovery dropped: $arraysWithElem/$arrays');
  });

  test('enum item labels are recovered and printable', () {
    var files = 0, enums = 0, enumsWithItems = 0;
    final fails = <String>[];
    for (final f in all) {
      final ViModel model;
      try {
        model = buildViModel(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      files++;
      for (final t in model.types) {
        if (t.kind != ViDataType.enumU8 && t.kind != ViDataType.enumU16 && t.kind != ViDataType.enumU32) continue;
        enums++;
        if (t.enumItems.isEmpty) continue;
        enumsWithItems++;
        for (final it in t.enumItems) {
          if (it.isEmpty || it.runes.any((c) => c < 0x20 || c >= 0x7f)) {
            if (fails.length < 8) fails.add('"$it" in ${f.path.split('/').last}');
          }
        }
      }
    }
    expect(files, greaterThan(0));
    expect(enums, greaterThan(0));
    expect(fails, isEmpty, reason: 'malformed enum items: $fails');
    // ratchet: most enums expose a parseable item list (probe ~96%).
    expect(enumsWithItems, greaterThan((enums * 0.80).floor()),
        reason: 'enum item recovery dropped: $enumsWithItems/$enums');
  });
}
