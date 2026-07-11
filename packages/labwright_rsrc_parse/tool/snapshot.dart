import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Regenerates the committed corpus snapshot (`corpus/snapshot.json`):
///
/// 1. **Per-VI feature groups** — for each VI (via the exact app decode path
///    `buildViModel`/`parseVi`) the front-panel object count, block-diagram
///    object count, and resource-block set, grouped by block set so
///    structurally-similar VIs cluster and each block list is written once.
///    `corpus_snapshot_test.dart` asserts these EXACTLY — a count or block-set
///    change in either direction is a reviewed snapshot diff.
/// 2. **Metric sections** — the aggregate corpus censuses (coverage axes as
///    raw counts, section-law numerator/denominator pairs, aux-decoder
///    censuses). The corpus tests measure them (single source of truth: the
///    code that asserts is the code that measures); this tool re-runs those
///    tests with `LABWRIGHT_SNAPSHOT_UPDATE` pointed at a fragment directory
///    where each `expectCorpusSnapshot` call site records its section, then
///    merges the fragments in. `snapshot_check.dart` asserts them EXACTLY.
///
/// Run: `dart run tool/snapshot.dart [corpusDir]` (writes `<pkg>/corpus/snapshot.json`)
/// Default corpusDir = the whole gitignored corpus fetched by tool/fetch_corpus.dart,
/// resolved by the shared [corpusBaseDir]; enumeration via [listCorpusVis]
/// (recursive, symlinks excluded). Aborts without writing when the test run
/// fails — laws must hold before numbers are pinned.

/// The corpus test files that own metric sections.
const _sectionTests = [
  'test/const_value_census_test.dart',
  'test/corpus_coverage_test.dart',
  'test/corpus_invariants_test.dart',
  'test/invariants_test.dart',
  'test/aux_blocks_test.dart',
  'test/writer_scoreboard_test.dart',
  'test/signal_type_census_test.dart',
  'test/wire_route_census_test.dart',
];

void main(List<String> args) {
  final base = corpusBaseDir().path;
  final dir = Directory(args.isNotEmpty ? args[0] : '$base/vi');
  if (!dir.existsSync()) {
    stderr.writeln('corpus dir not found: ${dir.path}');
    exit(1);
  }
  final vis = listCorpusVis(dir);

  final root = '${dir.path}/';
  // Group VIs by their resource-block SET, so structurally-similar VIs cluster
  // together and the block list is recorded once per group instead of once per
  // file. Each file carries its front-panel (fp) and block-diagram (bd) object
  // counts. VIs that fail to decode go in a separate `errors` list.
  final files = <String, List<Map<String, dynamic>>>{}; // blocksKey -> file records
  final blockSet = <String, List<String>>{}; // blocksKey -> the block list
  final errors = <Map<String, dynamic>>[];
  for (final f in vis) {
    final name = f.path.startsWith(root) ? f.path.substring(root.length).replaceAll('\\', '/') : f.path;
    try {
      final bytes = f.readAsBytesSync();
      final blocks = parseVi(bytes).blocks.toSet().toList()..sort();
      final m = buildViModel(bytes);
      final gk = blocks.join(',');
      blockSet[gk] = blocks;
      (files[gk] ??= []).add({
        'name': name,
        'fp': m.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
        'bd': m.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
      });
    } catch (e) {
      errors.add({'name': name, 'error': e.toString()});
    }
  }
  // Deterministic, diff-stable ordering: groups by block-set, files within a
  // group by name, errors by name. A file changing its block-set moves groups
  // but every group keeps its position, so diffs stay localized.
  final groupKeys = blockSet.keys.toList()..sort();
  for (final list in files.values) {
    list.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  }
  errors.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final sections = _measureSections(base);
  if (sections == null) {
    exitCode = 1;
    return;
  }

  // Pretty outer structure; each metric section key is one line, each file
  // record stays compact on one line, and each group's block list is one line
  // — readable and diffable over the whole corpus.
  const note =
      'Exact corpus snapshot: `sections` holds the aggregate metrics the '
      'corpus tests measure (asserted exactly by test/snapshot_check.dart); '
      '`groups` cluster VIs by resource-block set, each file recording '
      'fp=front-panel and bd=block-diagram object counts (asserted exactly by '
      'corpus_snapshot_test.dart). Any change is a reviewed regeneration diff.';
  final sectionsJson = const JsonEncoder.withIndent('  ').convert({
    for (final k in sections.keys.toList()..sort())
      k: {
        for (final key in sections[k]!.keys.toList()..sort()) key: sections[k]![key],
      },
  });
  final buf = StringBuffer()
    ..writeln('{')
    ..writeln('  "generatedBy": "packages/labwright_rsrc_parse/tool/snapshot.dart",')
    ..writeln('  "note": ${jsonEncode(note)},')
    ..writeln('  "sections": ${sectionsJson.replaceAll('\n', '\n  ')},')
    ..writeln('  "groups": [');
  for (var gi = 0; gi < groupKeys.length; gi++) {
    final gk = groupKeys[gi];
    final gtail = gi == groupKeys.length - 1 ? '' : ',';
    buf
      ..writeln('    {')
      ..writeln('      "blocks": ${jsonEncode(blockSet[gk])},')
      ..writeln('      "files": [');
    final list = files[gk]!;
    for (var fi = 0; fi < list.length; fi++) {
      buf.writeln('        ${jsonEncode(list[fi])}${fi == list.length - 1 ? '' : ','}');
    }
    buf
      ..writeln('      ]')
      ..writeln('    }$gtail');
  }
  buf
    ..writeln('  ],')
    ..writeln('  "errors": [');
  for (var ei = 0; ei < errors.length; ei++) {
    buf.writeln('    ${jsonEncode(errors[ei])}${ei == errors.length - 1 ? '' : ','}');
  }
  buf
    ..writeln('  ]')
    ..writeln('}');
  File('$base/snapshot.json').writeAsStringSync(buf.toString());
  final nFiles = files.values.fold<int>(0, (a, g) => a + g.length);
  stdout.writeln(
    'snapshot: $nFiles VIs in ${groupKeys.length} block-set groups · '
    '${errors.length} errors · ${sections.length} metric sections',
  );
}

/// Runs the section-owning corpus tests in record mode and returns the merged
/// sections (existing snapshot sections overlaid with the fresh fragments), or
/// null when the test run failed.
Map<String, Map<String, Object?>>? _measureSections(String corpusBase) {
  final pkgRoot = Directory(corpusBase).parent.path;
  final fragments = Directory.systemTemp.createTempSync('lw_rsrc_snapshot_');
  try {
    stdout.writeln('re-measuring: dart test -t corpus ${_sectionTests.join(' ')}');
    final result = Process.runSync(
      'dart',
      [
        'test',
        '-t',
        'corpus',
        ..._sectionTests,
      ],
      workingDirectory: pkgRoot,
      environment: {'LABWRIGHT_SNAPSHOT_UPDATE': fragments.path},
    );
    stdout.write(result.stdout);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      stderr.writeln('test run failed (exit ${result.exitCode}) — snapshot NOT written');
      return null;
    }

    final sections = <String, Map<String, Object?>>{};
    final existing = File('$corpusBase/snapshot.json');
    if (existing.existsSync()) {
      final old = jsonDecode(existing.readAsStringSync()) as Map<String, dynamic>;
      (old['sections'] as Map?)?.forEach((k, v) => sections[k as String] = (v as Map).cast<String, Object?>());
    }
    var fresh = 0;
    for (final f in fragments.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
      if (!f.path.endsWith('.json')) continue;
      final section = f.uri.pathSegments.last.replaceAll('.json', '');
      sections[section] = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
      fresh++;
    }
    if (fresh == 0) {
      stderr.writeln('no snapshot fragments produced — snapshot NOT written');
      return null;
    }
    return sections;
  } finally {
    fragments.deleteSync(recursive: true);
  }
}
