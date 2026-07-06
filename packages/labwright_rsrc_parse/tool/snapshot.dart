import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// **Feature-presence snapshot** for the WHOLE VI corpus, grouped by structure.
///
/// For each VI (via the exact app decode path `buildViModel`/`parseVi`) records
/// the front-panel object count, block-diagram object count, and resource-block
/// set. VIs are grouped by their block set, so structurally-similar VIs cluster
/// and each block list is written once per group. `corpus_snapshot_test.dart`
/// reads this and fails if any VI *loses* a feature it had (counts dropping
/// toward 0, or a resource block disappearing) — so a refactor can't silently
/// take a VI "from something to nothing". Gaining features is fine (re-run).
///
/// Run: `dart run tool/snapshot.dart [corpusDir]`  (writes `<pkg>/corpus/snapshot.json`)
/// Default corpusDir = the whole gitignored corpus fetched by tool/fetch_corpus.dart.
/// Resolves this package's `corpus/` dir from CWD (the run may start at the repo
/// root or the package dir), checking the package-relative and package-local
/// locations. The corpus + its committed JSON live under the package now.
String _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/$pkgRel/sources.json').existsSync()) return '${d.path}/$pkgRel';
    if (File('${d.path}/corpus/sources.json').existsSync()) return '${d.path}/corpus';
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return 'corpus';
}

void main(List<String> args) {
  final base = _corpusBase();
  final dir = Directory(args.isNotEmpty ? args[0] : '$base/vi');
  if (!dir.existsSync()) {
    stderr.writeln('corpus dir not found: ${dir.path}');
    exit(1);
  }
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final root = vis.isEmpty ? dir.path : _commonRoot(vis.map((f) => f.path));
  // Group VIs by their resource-block SET, so structurally-similar VIs cluster
  // together and the block list is recorded once per group instead of once per
  // file. Each file carries its front-panel (fp) and block-diagram (bd) object
  // counts. VIs that fail to decode go in a separate `errors` list.
  final files = <String, List<Map<String, dynamic>>>{}; // blocksKey -> file records
  final blockSet = <String, List<String>>{}; // blocksKey -> the block list
  final errors = <Map<String, dynamic>>[];
  for (final f in vis) {
    final name = f.path.substring(root.length).replaceAll('\\', '/');
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

  // Pretty outer structure; each file record stays compact on one line and each
  // group's block list is one line — readable and diffable over the whole corpus.
  const note =
      'VIs grouped by resource-block set (structurally similar VIs '
      'cluster); each file records fp=front-panel and bd=block-diagram object '
      'counts. Regression guard only allows these to grow.';
  final buf = StringBuffer()
    ..writeln('{')
    ..writeln('  "generatedBy": "packages/labwright_rsrc_parse/tool/snapshot.dart",')
    ..writeln('  "note": ${jsonEncode(note)},')
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
    '${errors.length} errors',
  );
}

String _commonRoot(Iterable<String> paths) {
  final list = paths.toList();
  var prefix = list.first;
  for (final p in list) {
    while (!p.startsWith(prefix)) {
      prefix = prefix.substring(0, prefix.length - 1);
      if (prefix.isEmpty) return '';
    }
  }
  return prefix;
}
