@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

bool _hasNonPrintable(String s) => s.runes.any((c) => c < 0x20 || c >= 0x7f);

(Map<String, int>, List<String>) _summarizeVi(Uint8List bytes, String path) {
  final c = <String, int>{};
  final diags = <String>[];
  void n(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  void bad(String key, String msg) {
    n('bad:$key');
    if (diags.length < 4) diags.add('$key• $msg');
  }

  final ViModel model;
  try {
    model = buildViModel(Uint8List.fromList(bytes));
  } catch (_) {
    return (c, diags);
  }
  n('built');
  final name = path.split('/').last;

  try {
    final a = jsonEncode(viModelToJson(model));
    final b = jsonEncode(viModelToJson(buildViModel(Uint8List.fromList(bytes))));
    if (a != b) {
      bad('json', 'NONDET $name');
    } else {
      final decoded = jsonDecode(a);
      if (decoded is! Map || !decoded.containsKey('blockDiagrams')) bad('json', 'BADROOT $name');
    }
  } catch (e) {
    bad('json', 'THREW $name: $e');
  }

  for (final d in [...model.blockDiagrams, ...model.frontPanelDiagrams]) {
    n('diagrams');
    final json = viDiagramToJson(d);
    final emitted = (json['objects'] as List).map((o) => (o as Map)['oid'] as int).toSet();
    final missing = d.nodes.where((o) => !emitted.contains(o.oid));
    if (missing.isNotEmpty) {
      bad('drawable', 'MISSING ${missing.first.oid} in $name/${d.sectionTag}');
      break;
    }
  }

  n('types', model.types.length);
  if (model.types.isNotEmpty) n('withTypes');
  n('unknownTypes', model.types.where((t) => t.kind == ViDataType.unknown).length);
  final named = namedTypes(model.types);
  n('named', named.length);
  if (named.isNotEmpty) n('hasNames');
  for (final t in named) {
    final x = t.name!;
    if (x.isEmpty || _hasNonPrintable(x) || !RegExp(r'[A-Za-z]').hasMatch(x)) bad('name', '"$x" in $name');
  }

  for (final t in model.types) {
    if (t.kind == ViDataType.cluster) {
      n('clusters');
      if (t.members.isNotEmpty) {
        n('clustersWithMembers');
        for (final i in t.members) {
          if (i < 0 || i >= model.types.length) bad('oobMember', 'OOB member $i in $name');
        }
        n('fields', clusterFields(t, model.types).length);
      }
    } else if (t.kind == ViDataType.array) {
      n('arrays');
      if (t.elementIndex != null) {
        n('arraysWithElem');
        if (t.elementIndex! < 0 || t.elementIndex! >= model.types.length) {
          bad('oobElem', 'OOB elem ${t.elementIndex} in $name');
        }
      }
    } else if (const {ViDataType.enumU8, ViDataType.enumU16, ViDataType.enumU32}.contains(t.kind)) {
      n('enums');
      if (t.enumItems.isNotEmpty) {
        n('enumsWithItems');
        for (final it in t.enumItems) {
          if (it.isEmpty || _hasNonPrintable(it)) bad('enum', '"$it" in $name');
        }
      }
    }
  }
  return (c, diags);
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('IR JSON corpus tests (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final Map<String, int> C;
  late final List<String> diags;
  setUpAll(() async {
    C = {};
    diags = [];
    for (final (counts, d) in await corpusParallel(all, _summarizeVi)) {
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

  test('VCTP named typedefs are recovered and look like real identifiers', () {
    expect(L('built'), greaterThan(0));
    expect(L('named'), greaterThan(0));
    expect(L('bad:name'), 0, reason: 'malformed recovered type names: ${D('name')}');
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

  test('enum item labels are recovered and printable', () {
    expect(L('enums'), greaterThan(0));
    expect(L('bad:enum'), 0, reason: 'malformed enum items: ${D('enum')}');
    expect(
      L('enumsWithItems'),
      greaterThan((L('enums') * 0.80).floor()),
      reason: 'enum item recovery dropped: ${L('enumsWithItems')}/${L('enums')}',
    );
  });
}
