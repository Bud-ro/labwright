import 'dart:convert';
import 'dart:io';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

/// Per-VI **feature-presence snapshot** for the canonical picotech corpus.
///
/// Records, per VI (via the exact app decode path `buildViModel`/`parseVi`),
/// whether the key features are present: front-panel object count, block-diagram
/// object count, and the resource-block set. `corpus_snapshot_test.dart` reads
/// this and fails if any VI *loses* a feature it had (counts dropping toward 0,
/// or a resource block disappearing) — so a refactor can't silently take a VI
/// "from something to nothing". Gaining features is fine (re-run to record it).
///
/// Run: `dart run tool/snapshot.dart [corpusDir]`  (writes corpus/snapshot.json)
/// Default corpusDir = the gitignored picotech sample fetched by tool/fetch_corpus.dart.
String _defaultSampleDir() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/corpus/sources.json').existsSync()) {
      return '${d.path}/vi-corpus/picotech_picosdk-ni-labview-examples';
    }
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return 'vi-corpus/picotech_picosdk-ni-labview-examples';
}

void main(List<String> args) {
  final dir = Directory(args.isNotEmpty ? args[0] : _defaultSampleDir());
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
    'generatedBy': 'packages/labwright_videcode/tool/snapshot.dart',
    'note': 'Per-VI feature presence (fp=front-panel objects, bd=block-diagram objects, blocks=resource tags). Regression guard only allows these to grow.',
    'vis': out,
  };
  File('../../corpus/snapshot.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(snap)}\n');
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
