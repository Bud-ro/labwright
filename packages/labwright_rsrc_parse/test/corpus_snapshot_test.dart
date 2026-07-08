@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Per-VI feature-presence ratchet against corpus/snapshot.json (written by tool/snapshot.dart over
/// the WHOLE corpus): front-panel/block-diagram object counts must not drop and the resource-block
/// set must stay a superset. Gaining features is fine — re-run the tool to record them. This is what
/// catches "a VI went from something to nothing". Skips when corpus or snapshot is absent.
typedef _Snap = ({String path, bool error, int fp, int bd, List<String> blocks});

_Snap _summarizeVi(Uint8List bytes, String path) {
  try {
    final blocks = parseVi(bytes).blocks.toSet().toList()..sort();
    final m = buildViModel(bytes);
    return (
      path: path,
      error: false,
      fp: m.frontPanelDiagrams.fold(0, (a, b) => a + b.objects.length),
      bd: m.blockDiagrams.fold(0, (a, b) => a + b.objects.length),
      blocks: blocks,
    );
  } catch (_) {
    return (path: path, error: true, fp: 0, bd: 0, blocks: const <String>[]);
  }
}

String _commonRoot(Iterable<String> paths) => paths.reduce((prefix, p) {
  while (!p.startsWith(prefix)) {
    prefix = prefix.substring(0, prefix.length - 1);
    if (prefix.isEmpty) return '';
  }
  return prefix;
});

void main() {
  final all = corpusVis();
  final snapFile = corpusSnapshotFile();
  if (all.isEmpty || !snapFile.existsSync()) {
    test('corpus feature snapshot (skipped: corpus/snapshot not present)', () {}, skip: true);
    return;
  }

  final root = _commonRoot(all.map((f) => f.path));
  final byKey = {for (final f in all) f.path.substring(root.length).replaceAll('\\', '/'): f.path};
  // The snapshot groups files by block-set; flatten back to per-file expectations.
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
    final res = await corpusParallel(all, _summarizeVi);
    byPath = {for (final s in res) s.path: s};
  });

  test('no VI loses front-panel/block-diagram objects or resource blocks', () {
    final regressions = <String>[];
    for (final MapEntry(key: key, value: want) in snap.entries) {
      if (want.containsKey('error')) continue; // was already failing; not a regression target
      final s = byPath[byKey[key]];
      if (s == null) continue;
      if (s.error) {
        regressions.add('$key: now throws on decode (was decodable)');
        continue;
      }
      if (s.fp < ((want['fp'] as int?) ?? 0)) regressions.add('$key: front-panel ${want['fp']} -> ${s.fp}');
      if (s.bd < ((want['bd'] as int?) ?? 0)) regressions.add('$key: block-diagram ${want['bd']} -> ${s.bd}');
      final have = s.blocks.toSet();
      final lost = ((want['blocks'] as List?) ?? const []).cast<String>().where((b) => !have.contains(b)).toList();
      if (lost.isNotEmpty) regressions.add('$key: lost blocks $lost');
    }
    expect(regressions, isEmpty, reason: 'feature regressions:\n${regressions.take(20).join('\n')}');
  });
}
