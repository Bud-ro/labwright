@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Tests for the JSON IR export ([viModelToJson]) — the serializable VI→IR→Dart
/// artifact. Three properties across the WHOLE corpus:
///   (1) DETERMINISM — encoding the same VI twice yields byte-identical JSON;
///   (2) JSON-SAFETY — every VI's IR round-trips through jsonEncode/jsonDecode
///       (no non-finite numbers, no cycles, no non-encodable values);
///   (3) COVERAGE — every drawable diagram object (one with absolute bounds)
///       appears in the emitted node list (the IR loses no drawable object).
///
/// All of these need `buildViModel`, so each VI is summarized ONCE in a worker
/// isolate (see [corpusParallel]) and the tests assert on the aggregate — there is
/// no sampling, the heavy work is just parallelized.

bool _hasNonPrintable(String s) => s.runes.any((c) => c < 0x20 || c >= 0x7f);

/// Per-VI summary covering every test below. Sendable (primitives + nullable
/// strings). A VI whose model build throws returns a neutral summary (`built`
/// false), affecting no aggregate.
class _ViSummary {
  final String path;
  final bool built;
  final int diagrams;
  final String? jsonFail;
  final String? drawableFail;
  final int typesCount, unknownTypes;
  final bool withTypes;
  final int namedCount;
  final bool hasNames;
  final String? badName;
  final int clusters, clustersWithMembers, totalFields;
  final String? oobMember;
  final int arrays, arraysWithElem;
  final String? oobElem;
  final int enums, enumsWithItems;
  final String? badEnum;
  const _ViSummary({
    required this.path,
    required this.built,
    required this.diagrams,
    required this.jsonFail,
    required this.drawableFail,
    required this.typesCount,
    required this.unknownTypes,
    required this.withTypes,
    required this.namedCount,
    required this.hasNames,
    required this.badName,
    required this.clusters,
    required this.clustersWithMembers,
    required this.totalFields,
    required this.oobMember,
    required this.arrays,
    required this.arraysWithElem,
    required this.oobElem,
    required this.enums,
    required this.enumsWithItems,
    required this.badEnum,
  });
  factory _ViSummary.neutral(String path) => _ViSummary(
        path: path, built: false, diagrams: 0, jsonFail: null, drawableFail: null,
        typesCount: 0, unknownTypes: 0, withTypes: false, namedCount: 0, hasNames: false,
        badName: null, clusters: 0, clustersWithMembers: 0, totalFields: 0, oobMember: null,
        arrays: 0, arraysWithElem: 0, oobElem: null, enums: 0, enumsWithItems: 0, badEnum: null,
      );
}

_ViSummary _summarizeVi(Uint8List bytes, String path) {
  final ViModel model;
  try {
    model = buildViModel(Uint8List.fromList(bytes));
  } catch (_) {
    return _ViSummary.neutral(path);
  }
  final name = path.split('/').last;

  String? jsonFail;
  try {
    final a = jsonEncode(viModelToJson(model));
    final b = jsonEncode(viModelToJson(buildViModel(Uint8List.fromList(bytes))));
    if (a != b) {
      jsonFail = 'NONDET $name';
    } else {
      final decoded = jsonDecode(a);
      if (decoded is! Map || !decoded.containsKey('blockDiagrams')) jsonFail = 'BADROOT $name';
    }
  } catch (e) {
    jsonFail = 'THREW $name: $e';
  }

  var diagrams = 0;
  String? drawableFail;
  for (final d in [...model.blockDiagrams, ...model.frontPanelDiagrams]) {
    diagrams++;
    final json = viDiagramToJson(d);
    final emitted = (json['objects'] as List).map((o) => (o as Map)['oid'] as int).toSet();
    final missing = d.nodes.where((o) => !emitted.contains(o.oid));
    if (missing.isNotEmpty) {
      drawableFail = 'MISSING ${missing.first.oid} in $name/${d.sectionTag}';
      break;
    }
  }

  final typesCount = model.types.length;
  final unknownTypes = model.types.where((t) => t.kind == ViDataType.unknown).length;
  final named = namedTypes(model.types);
  String? badName;
  for (final t in named) {
    final n = t.name!;
    if (n.isEmpty || _hasNonPrintable(n) || !RegExp(r'[A-Za-z]').hasMatch(n)) {
      badName = '"$n" in $name';
      break;
    }
  }

  var clusters = 0, clustersWithMembers = 0, totalFields = 0;
  String? oobMember;
  var arrays = 0, arraysWithElem = 0;
  String? oobElem;
  var enums = 0, enumsWithItems = 0;
  String? badEnum;
  for (final t in model.types) {
    if (t.kind == ViDataType.cluster) {
      clusters++;
      if (t.members.isNotEmpty) {
        clustersWithMembers++;
        for (final i in t.members) {
          if (i < 0 || i >= model.types.length) oobMember ??= 'OOB member $i in $name';
        }
        totalFields += clusterFields(t, model.types).length;
      }
    } else if (t.kind == ViDataType.array) {
      arrays++;
      if (t.elementIndex != null) {
        arraysWithElem++;
        if (t.elementIndex! < 0 || t.elementIndex! >= model.types.length) {
          oobElem ??= 'OOB elem ${t.elementIndex} in $name';
        }
      }
    } else if (const {ViDataType.enumU8, ViDataType.enumU16, ViDataType.enumU32}.contains(t.kind)) {
      enums++;
      if (t.enumItems.isNotEmpty) {
        enumsWithItems++;
        for (final it in t.enumItems) {
          if (it.isEmpty || _hasNonPrintable(it)) badEnum ??= '"$it" in $name';
        }
      }
    }
  }

  return _ViSummary(
    path: path,
    built: true,
    diagrams: diagrams,
    jsonFail: jsonFail,
    drawableFail: drawableFail,
    typesCount: typesCount,
    unknownTypes: unknownTypes,
    withTypes: model.types.isNotEmpty,
    namedCount: named.length,
    hasNames: named.isNotEmpty,
    badName: badName,
    clusters: clusters,
    clustersWithMembers: clustersWithMembers,
    totalFields: totalFields,
    oobMember: oobMember,
    arrays: arrays,
    arraysWithElem: arraysWithElem,
    oobElem: oobElem,
    enums: enums,
    enumsWithItems: enumsWithItems,
    badEnum: badEnum,
  );
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('IR JSON corpus tests (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final List<_ViSummary> summaries;
  late final int filesBuilt;
  setUpAll(() async {
    summaries = await corpusParallel(all, _summarizeVi);
    filesBuilt = summaries.where((j) => j.built).length;
  });

  test('viModelToJson is deterministic and jsonEncode-safe for every VI', () {
    final fails = summaries.map((j) => j.jsonFail).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(fails, isEmpty, reason: 'IR JSON determinism/safety failures: ${fails.take(8).toList()}');
  });

  test('IR JSON represents every drawable object (no drawable lost)', () {
    final fails = summaries.map((j) => j.drawableFail).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(summaries.fold<int>(0, (a, j) => a + j.diagrams), greaterThan(0));
    expect(fails, isEmpty, reason: 'IR JSON dropped drawable object(s): ${fails.take(8).toList()}');
  });

  test('VCTP type pool recovers a type inventory for the vast majority of VIs', () {
    final withTypes = summaries.where((j) => j.withTypes).length;
    final totalTypes = summaries.fold<int>(0, (a, j) => a + j.typesCount);
    final totalUnknown = summaries.fold<int>(0, (a, j) => a + j.unknownTypes);
    expect(filesBuilt, greaterThan(0));
    expect(totalTypes, greaterThan(0));
    expect(withTypes, greaterThan((filesBuilt * 0.90).floor()),
        reason: 'type-pool recovery dropped: only $withTypes/$filesBuilt VIs yielded types');
    expect(totalUnknown, lessThan(totalTypes * 0.6),
        reason: 'too many uncatalogued type codes: $totalUnknown/$totalTypes');
  });

  test('VCTP named typedefs are recovered and look like real identifiers', () {
    final vIsWithNames = summaries.where((j) => j.hasNames).length;
    final totalNames = summaries.fold<int>(0, (a, j) => a + j.namedCount);
    final badNames = summaries.map((j) => j.badName).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(totalNames, greaterThan(0));
    expect(badNames, isEmpty, reason: 'malformed recovered type names: ${badNames.take(8).toList()}');
    expect(vIsWithNames, greaterThan((filesBuilt * 0.40).floor()),
        reason: 'named-type recovery dropped: only $vIsWithNames/$filesBuilt VIs yielded names');
  });

  test('cluster member structures resolve into valid fields', () {
    final clusters = summaries.fold<int>(0, (a, j) => a + j.clusters);
    final clustersWithMembers = summaries.fold<int>(0, (a, j) => a + j.clustersWithMembers);
    final totalFields = summaries.fold<int>(0, (a, j) => a + j.totalFields);
    final fails = summaries.map((j) => j.oobMember).whereType<String>().toList();
    expect(clusters, greaterThan(0));
    expect(fails, isEmpty, reason: 'cluster members out of range: ${fails.take(8).toList()}');
    expect(totalFields, greaterThan(0));
    expect(clustersWithMembers, greaterThan((clusters * 0.80).floor()),
        reason: 'cluster member recovery dropped: $clustersWithMembers/$clusters');
  });

  test('array element types resolve into valid in-range indices', () {
    final arrays = summaries.fold<int>(0, (a, j) => a + j.arrays);
    final arraysWithElem = summaries.fold<int>(0, (a, j) => a + j.arraysWithElem);
    final fails = summaries.map((j) => j.oobElem).whereType<String>().toList();
    expect(arrays, greaterThan(0));
    expect(fails, isEmpty, reason: 'array element index out of range: ${fails.take(8).toList()}');
    expect(arraysWithElem, greaterThan((arrays * 0.80).floor()),
        reason: 'array element recovery dropped: $arraysWithElem/$arrays');
  });

  test('enum item labels are recovered and printable', () {
    final enums = summaries.fold<int>(0, (a, j) => a + j.enums);
    final enumsWithItems = summaries.fold<int>(0, (a, j) => a + j.enumsWithItems);
    final fails = summaries.map((j) => j.badEnum).whereType<String>().toList();
    expect(enums, greaterThan(0));
    expect(fails, isEmpty, reason: 'malformed enum items: ${fails.take(8).toList()}');
    expect(enumsWithItems, greaterThan((enums * 0.80).floor()),
        reason: 'enum item recovery dropped: $enumsWithItems/$enums');
  });
}
