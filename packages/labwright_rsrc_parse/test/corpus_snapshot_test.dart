@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Per-VI feature-presence regression guard (see tool/snapshot.dart).
///
/// Reads corpus/snapshot.json (machine-written over the WHOLE corpus) and
/// re-derives each VI's features via the app decode path, asserting nothing was
/// LOST: front-panel and block-diagram object counts must not drop below the
/// snapshot, and the resource-block set must remain a superset. Gaining features
/// is fine — re-run the tool to record the higher numbers. Skips when the corpus
/// or snapshot is absent (CI-safe). This is what catches "a VI went from
/// something to nothing".
///
/// Every VI is re-derived ONCE in a worker isolate ([corpusParallel]); the test
/// compares the aggregate against the snapshot — no sampling, the per-VI build is
/// just parallelized across cores.

/// Per-VI feature summary. Sendable across isolates.
class _Snap {
  final String path;
  final bool error;
  final int fp, bd;
  final List<String> blocks;
  const _Snap({
    required this.path,
    required this.error,
    required this.fp,
    required this.bd,
    required this.blocks,
  });
}

_Snap _snapSumm(Uint8List bytes, String path) {
  try {
    final blocks = parseVi(bytes).blocks.toSet().toList()..sort();
    final m = buildViModel(bytes);
    return _Snap(
      path: path,
      error: false,
      fp: m.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
      bd: m.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
      blocks: blocks,
    );
  } catch (_) {
    return _Snap(path: path, error: true, fp: 0, bd: 0, blocks: const []);
  }
}

void main() {
  final all = corpusVis();
  final snapFile = corpusSnapshotFile();
  if (all.isEmpty || !snapFile.existsSync()) {
    test('corpus feature snapshot (skipped: corpus/snapshot not present)', () {}, skip: true);
    return;
  }

  // Key each VI relative to the corpus common root, exactly as tool/snapshot.dart
  // does, so keys line up with snapshot.json.
  final root = _commonRoot(all.map((f) => f.path));
  final byKey = {for (final f in all) f.path.substring(root.length).replaceAll('\\', '/'): f.path};
  // The snapshot groups files by block-set; flatten back to per-file expectations
  // (each group's block list applies to every file under it).
  final snapJson = jsonDecode(snapFile.readAsStringSync()) as Map;
  final snap = <String, Map<String, dynamic>>{};
  for (final g in (snapJson['groups'] as List).cast<Map<String, dynamic>>()) {
    final blocks = (g['blocks'] as List).cast<String>();
    for (final f in (g['files'] as List).cast<Map<String, dynamic>>()) {
      snap[f['name'] as String] = {'fp': f['fp'], 'bd': f['bd'], 'blocks': blocks};
    }
  }
  for (final e in ((snapJson['errors'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
    snap[e['name'] as String] = {'error': e['error']};
  }

  late final Map<String, _Snap> byPath;
  setUpAll(() async {
    final res = await corpusParallel(all, _snapSumm);
    byPath = {for (final s in res) s.path: s};
  });

  test('no VI loses front-panel/block-diagram objects or resource blocks', () {
    final regressions = <String>[];
    for (final entry in snap.entries) {
      final key = entry.key;
      final want = entry.value;
      if (want.containsKey('error')) continue; // was already failing; not a regression target
      final path = byKey[key];
      if (path == null) continue; // file not in this checkout
      final s = byPath[path];
      if (s == null) continue; // not summarized (should not happen)
      if (s.error) {
        regressions.add('$key: now throws on decode (was decodable)');
        continue;
      }
      final wantFp = (want['fp'] as int?) ?? 0;
      final wantBd = (want['bd'] as int?) ?? 0;
      final wantBlocks = ((want['blocks'] as List?) ?? const []).cast<String>();
      if (s.fp < wantFp) regressions.add('$key: front-panel $wantFp -> ${s.fp}');
      if (s.bd < wantBd) regressions.add('$key: block-diagram $wantBd -> ${s.bd}');
      final have = s.blocks.toSet();
      final lost = wantBlocks.where((b) => !have.contains(b)).toList();
      if (lost.isNotEmpty) regressions.add('$key: lost blocks $lost');
    }
    expect(regressions, isEmpty, reason: 'feature regressions:\n${regressions.take(20).join('\n')}');
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
