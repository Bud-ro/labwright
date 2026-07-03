@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Tests for the honest IR->Dart structural scaffold ([generateDartScaffold]).
/// Across the WHOLE corpus:
///   (1) DETERMINISM — same VI yields an identical scaffold string;
///   (2) HONEST MARKER — every scaffold carries the no-dataflow disclaimer
///       ([scaffoldMarker]) so generated stubs can never masquerade as logic;
///   (3) COVERAGE RATCHET — every block-diagram structure and node appears in
///       the output (by its `[oid N]` marker); the scaffold drops no logic
///       element, even if it can't recover the wiring between them.
///
/// Each VI is summarized ONCE in a worker isolate ([corpusParallel]); the tests
/// assert on the aggregate (no sampling — the heavy work is just parallelized).

class _S {
  final bool built;
  final String? scaffoldFail;
  final int checked;
  final String? missingOid;
  final bool withCaptions;
  final String? captionFail;
  final bool withSubVis;
  final String? subviFail;
  const _S({
    required this.built,
    required this.scaffoldFail,
    required this.checked,
    required this.missingOid,
    required this.withCaptions,
    required this.captionFail,
    required this.withSubVis,
    required this.subviFail,
  });
  factory _S.neutral() => const _S(
        built: false, scaffoldFail: null, checked: 0, missingOid: null,
        withCaptions: false, captionFail: null, withSubVis: false, subviFail: null,
      );
}

_S _scaffoldSumm(Uint8List bytes, String path) {
  final ViModel model;
  try {
    model = buildViModel(Uint8List.fromList(bytes));
  } catch (_) {
    return _S.neutral();
  }
  final name = path.split('/').last;
  final out = generateDartScaffold(model);

  String? scaffoldFail;
  if (out != generateDartScaffold(model)) {
    scaffoldFail = 'NONDET $name';
  } else if (!out.contains(scaffoldMarker)) {
    scaffoldFail = 'NOMARKER $name';
  }

  var checked = 0;
  String? missingOid;
  for (final d in model.blockDiagrams) {
    final logic = d.objects.where(
        (o) => o.category == ViObjectKind.structure || o.category == ViObjectKind.node);
    if (logic.isEmpty) continue;
    for (final o in logic) {
      checked++;
      if (!out.contains('[oid ${o.oid}]')) {
        missingOid = 'MISSING oid ${o.oid} (${o.category.name}) in $name/${d.sectionTag}';
        break;
      }
    }
    if (missingOid != null) break;
  }

  final caps = model.captions;
  var withCaptions = false;
  String? captionFail;
  if (caps.isNotEmpty) {
    withCaptions = true;
    if (!out.contains(_oneLineForTest(caps.first))) {
      captionFail = 'CAPTION MISSING in $name';
    } else if (caps.length > 50 && !out.contains('(+${caps.length - 50} more not shown)')) {
      captionFail = 'SILENT CAP in $name';
    }
  }

  var withSubVis = false;
  String? subviFail;
  if (model.subViNames.isNotEmpty) {
    withSubVis = true;
    for (final s in model.subViNames) {
      if (!out.contains(_oneLineForTest(s))) {
        subviFail = 'SUBVI "$s" missing in $name';
        break;
      }
    }
  }

  return _S(
    built: true,
    scaffoldFail: scaffoldFail,
    checked: checked,
    missingOid: missingOid,
    withCaptions: withCaptions,
    captionFail: captionFail,
    withSubVis: withSubVis,
    subviFail: subviFail,
  );
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('Dart scaffold corpus tests (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  late final List<_S> S;
  late final int filesBuilt;
  setUpAll(() async {
    S = await corpusParallel(all, _scaffoldSumm);
    filesBuilt = S.where((s) => s.built).length;
  });

  test('generateDartScaffold is deterministic and always carries the honest marker', () {
    final fails = S.map((s) => s.scaffoldFail).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(fails, isEmpty, reason: 'scaffold determinism/marker failures: ${fails.take(8).toList()}');
  });

  test('scaffold represents every block-diagram structure and node (no logic dropped)', () {
    final checked = S.fold<int>(0, (a, s) => a + s.checked);
    final fails = S.map((s) => s.missingOid).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(checked, greaterThan(0));
    expect(fails, isEmpty, reason: 'scaffold dropped logic element(s): ${fails.take(8).toList()}');
  });

  test('scaffold surfaces candidate parameters (captions) without silent truncation', () {
    final withCaptions = S.where((s) => s.withCaptions).length;
    final fails = S.map((s) => s.captionFail).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(withCaptions, greaterThan(0));
    expect(fails, isEmpty, reason: 'caption surfacing failures: ${fails.take(8).toList()}');
  });

  test('scaffold lists every recovered subVI name in its header', () {
    final withSubVis = S.where((s) => s.withSubVis).length;
    final fails = S.map((s) => s.subviFail).whereType<String>().toList();
    expect(filesBuilt, greaterThan(0));
    expect(withSubVis, greaterThan(0), reason: 'no VI exposed subVI names — recovery regressed');
    expect(fails, isEmpty, reason: 'scaffold dropped subVI name(s): ${fails.take(8).toList()}');
  });
}

/// Mirrors the scaffold's one-line caption normalization so the test compares the
/// same form that is emitted (newlines/control chars collapsed, `*/` neutralized).
String _oneLineForTest(String s) => s
    .replaceAll(RegExp(r'[\x00-\x1f]+'), ' ')
    .replaceAll('*/', '* /')
    .trim();
