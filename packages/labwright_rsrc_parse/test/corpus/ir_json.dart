import 'dart:convert';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';
import '../shape_probe.dart';

/// Counts, then diagnostics.
List<Object?> _summarizeVi(CorpusVi vi) {
  final bytes = vi.bytes;
  final path = vi.path;
  final c = <String, int>{};
  final diags = <String>[];
  void n(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  void bad(String key, String msg) {
    n('bad:$key');
    if (diags.length < 4) diags.add('$key• $msg');
  }

  final model = vi.model;
  if (model == null) return [c, diags];
  n('built');
  final name = path.split('/').last;

  try {
    final json = viModelToJson(model);
    jsonEncode(json);
    if (!json.containsKey('blockDiagrams')) bad('json', 'BADROOT $name');
    if (!_same(json, viModelToJson(buildViModel(bytes)))) bad('json', 'NONDET $name');
  } catch (e) {
    bad('json', 'THREW $name: $e');
  }

  for (final (tag, heap, json) in <(String, HeapObjectTree, Map<String, Object?>)>[
    for (final d in model.blockDiagrams) ('BDHb', d, bdDiagramToJson(d)),
    for (final p in model.frontPanels) ('FPHb', p, fpPanelToJson(p)),
  ]) {
    n('diagrams');
    final emitted = (json['objects'] as List<Map<String, Object?>>).map((o) => o['oid'] as int).toSet();
    final missing = heap.objects.where((o) => o.absBounds != null).where((o) => !emitted.contains(o.oid));
    if (missing.isNotEmpty) {
      bad('drawable', 'MISSING ${missing.first.oid} in $name/$tag');
      break;
    }
  }

  n('types', model.types.length);
  if (model.types.isNotEmpty) n('withTypes');
  n('unknownTypes', model.types.where((t) => t.kind == ViDataType.unknown).length);
  final named = namedTypes(model.types);
  n('named', named.length);
  if (named.isNotEmpty) n('hasNames');

  for (final t in model.types) {
    if (t is ViClusterType) {
      n('clusters');
      if (t.memberCount > 0) {
        n('clustersWithMembers');
        for (final i in t.memberIndices) {
          if (i >= model.types.length) bad('oobMember', 'OOB member $i in $name');
        }
        n('fields', clusterFields(t, model.types).length);
      }
    } else if (t is ViArrayType && t.kind == ViDataType.array) {
      n('arrays');
      n('arraysWithElem');
      if (t.elementIndex >= model.types.length) bad('oobElem', 'OOB elem ${t.elementIndex} in $name');
    } else if (t is ViEnumType) {
      n('enums');
      if (t.itemCount > 0) n('enumsWithItems');
    }
  }
  return [c, diags];
}

const irJsonLaw = CorpusLaw('ir_json', _summarizeVi);

bool _same(Object? a, Object? b) {
  if (a is Map) {
    if (b is! Map || a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || !_same(value, b[key])) return false;
    }
    return true;
  }
  if (a is List) {
    if (b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void irJsonTests() {
  late final Map<String, int> C;
  late final List<String> diags;
  setUpAll(() async {
    C = {};
    diags = [];
    for (final [counts as Map<String, int>, d as List<String>] in await irJsonLaw.results) {
      counts.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
      diags.addAll(d);
    }
  });

  int L(String k) => C[k] ?? 0;
  List<String> D(String key) => diags.where((x) => x.startsWith('$key•')).take(8).toList();

  test('viModelToJson is deterministic and jsonEncode-safe for every VI', () {
    expect(L('built'), greaterThan(0));
    expect(L('bad:json'), 0, reason: 'IR JSON determinism/safety failures: ${D('json')}');
  });

  test('IR JSON represents every drawable object (no drawable lost)', () {
    expect(L('built'), greaterThan(0));
    expect(L('diagrams'), greaterThan(0));
    expect(L('bad:drawable'), 0, reason: 'IR JSON dropped drawable object(s): ${D('drawable')}');
  });

  test('VCTP type pool recovers a type inventory for the vast majority of VIs', () {
    expect(L('built'), greaterThan(0));
    expect(L('types'), greaterThan(0));
    expect(
      L('withTypes'),
      greaterThan((L('built') * 0.90).floor()),
      reason: 'type-pool recovery dropped: only ${L('withTypes')}/${L('built')} VIs yielded types',
    );
    expect(
      L('unknownTypes'),
      lessThan(L('types') * 0.6),
      reason: 'too many uncatalogued type codes: ${L('unknownTypes')}/${L('types')}',
    );
  });

  test('VCTP labels are recovered for most types', () {
    expect(L('built'), greaterThan(0));
    expect(L('named'), greaterThan(0));
    expect(
      L('hasNames'),
      greaterThan((L('built') * 0.40).floor()),
      reason: 'named-type recovery dropped: only ${L('hasNames')}/${L('built')} VIs yielded names',
    );
  });

  test('cluster member structures resolve into valid fields', () {
    expect(L('clusters'), greaterThan(0));
    expect(L('bad:oobMember'), 0, reason: 'cluster members out of range: ${D('oobMember')}');
    expect(L('fields'), greaterThan(0));
    expect(
      L('clustersWithMembers'),
      greaterThan((L('clusters') * 0.80).floor()),
      reason: 'cluster member recovery dropped: ${L('clustersWithMembers')}/${L('clusters')}',
    );
  });

  test('array element types resolve into valid in-range indices', () {
    expect(L('arrays'), greaterThan(0));
    expect(L('bad:oobElem'), 0, reason: 'array element index out of range: ${D('oobElem')}');
    expect(
      L('arraysWithElem'),
      greaterThan((L('arrays') * 0.80).floor()),
      reason: 'array element recovery dropped: ${L('arraysWithElem')}/${L('arrays')}',
    );
  });

  test('enum item labels are recovered', () {
    expect(L('enums'), greaterThan(0));
    expect(
      L('enumsWithItems'),
      greaterThan((L('enums') * 0.80).floor()),
      reason: 'enum item recovery dropped: ${L('enumsWithItems')}/${L('enums')}',
    );
  });
}
