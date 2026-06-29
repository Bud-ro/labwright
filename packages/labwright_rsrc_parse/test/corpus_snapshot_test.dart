@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Per-VI feature-presence regression guard (see tool/snapshot.dart).
///
/// Reads corpus/snapshot.json (machine-written) and re-derives each VI's
/// features via the app decode path, asserting nothing was LOST: front-panel and
/// block-diagram object counts must not drop below the snapshot, and the
/// resource-block set must remain a superset. Gaining features is fine — re-run
/// the tool to record the higher numbers. Skips when the corpus or snapshot is
/// absent (CI-safe). This is what catches "a VI went from something to nothing".
void main() {
  final dir = corpusSampleDir;
  final snapFile = File('../../corpus/snapshot.json');
  if (!dir.existsSync() || !snapFile.existsSync()) {
    test('corpus feature snapshot (skipped: corpus/snapshot not present)', () {}, skip: true);
    return;
  }

  final vis = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final root = _commonRoot(vis.map((f) => f.path));
  final byKey = {for (final f in vis) f.path.substring(root.length).replaceAll('\\', '/'): f};
  final snap = (jsonDecode(snapFile.readAsStringSync()) as Map)['vis'] as Map;
  // Bound runtime: check the first 150 snapshot entries by key.
  final keys = (snap.keys.cast<String>().toList()..sort()).take(150).toList();

  test('no VI loses front-panel/block-diagram objects or resource blocks', () {
    final regressions = <String>[];
    for (final key in keys) {
      final want = snap[key] as Map;
      if (want.containsKey('error')) continue; // was already failing; not a regression target
      final f = byKey[key];
      if (f == null) continue; // file not in this checkout
      final bytes = f.readAsBytesSync();
      final m = buildViModel(bytes);
      final fp = m.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length);
      final bd = m.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length);
      final blocks = parseVi(bytes).blocks.toSet();
      final wantFp = (want['fp'] as int?) ?? 0;
      final wantBd = (want['bd'] as int?) ?? 0;
      final wantBlocks = ((want['blocks'] as List?) ?? const []).cast<String>();
      if (fp < wantFp) regressions.add('$key: front-panel $wantFp -> $fp');
      if (bd < wantBd) regressions.add('$key: block-diagram $wantBd -> $bd');
      final lost = wantBlocks.where((b) => !blocks.contains(b)).toList();
      if (lost.isNotEmpty) regressions.add('$key: lost blocks $lost');
    }
    expect(regressions, isEmpty, reason: 'feature regressions:\n${regressions.join('\n')}');
  });
}

String _commonRoot(Iterable<String> paths) {
  final list = paths.toList();
  if (list.isEmpty) return '';
  var prefix = list.first;
  for (final p in list) {
    while (!p.startsWith(prefix)) {
      prefix = prefix.substring(0, prefix.length - 1);
      if (prefix.isEmpty) return '';
    }
  }
  return prefix;
}
