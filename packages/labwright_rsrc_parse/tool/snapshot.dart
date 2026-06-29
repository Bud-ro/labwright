import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Per-VI **feature-presence snapshot** for the WHOLE VI corpus.
///
/// Records, per VI (via the exact app decode path `buildViModel`/`parseVi`),
/// whether the key features are present: front-panel object count, block-diagram
/// object count, and the resource-block set. `corpus_snapshot_test.dart` reads
/// this and fails if any VI *loses* a feature it had (counts dropping toward 0,
/// or a resource block disappearing) — so a refactor can't silently take a VI
/// "from something to nothing". Gaining features is fine (re-run to record it).
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
  final vis = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final root = vis.isEmpty ? dir.path : _commonRoot(vis.map((f) => f.path));
  final out = <String, dynamic>{};
  for (final f in vis) {
    final key = f.path.substring(root.length).replaceAll('\\', '/');
    try {
      final bytes = f.readAsBytesSync();
      final blocks = (parseVi(bytes).blocks.toSet().toList()..sort());
      final m = buildViModel(bytes);
      out[key] = {
        'fp': m.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
        'bd': m.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
        'blocks': blocks,
      };
    } catch (e) {
      out[key] = {'error': e.toString()};
    }
  }
  final snap = {
    'generatedBy': 'packages/labwright_rsrc_parse/tool/snapshot.dart',
    'note': 'Per-VI feature presence (fp=front-panel objects, bd=block-diagram objects, blocks=resource tags). Regression guard only allows these to grow.',
    'vis': out,
  };
  File('$base/snapshot.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(snap)}\n');
  final withFp = out.values.where((v) => ((v as Map)['fp'] as int? ?? 0) > 0).length;
  final withBd = out.values.where((v) => ((v as Map)['bd'] as int? ?? 0) > 0).length;
  stdout.writeln('snapshot: ${out.length} VIs · $withFp with front-panel objects · $withBd with block-diagram objects');
  for (final e in out.entries.where((e) => e.key.toLowerCase().contains('advancedtrigger'))) {
    stdout.writeln('  ${e.key} -> ${e.value}');
  }
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
