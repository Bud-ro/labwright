@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

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

void main() {
  final all = corpusVis();
  final snapFile = corpusSnapshotFile();

  final root = '${corpusViDir.path}/';
  final byKey = {for (final f in all) f.path.substring(root.length).replaceAll('\\', '/'): f.path};
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

  test('every VI keeps EXACTLY its snapshotted front-panel/block-diagram counts and block set', () {
    final diffs = <String>[];
    for (final MapEntry(key: key, value: want) in snap.entries) {
      final s = byPath[byKey[key]];
      if (s == null) continue;
      if (want.containsKey('error')) {
        if (!s.error) diffs.add('$key: now decodes (was a snapshotted decode error)');
        continue;
      }
      if (s.error) {
        diffs.add('$key: now throws on decode (was decodable)');
        continue;
      }
      if (s.fp != (want['fp'] as int)) diffs.add('$key: front-panel ${want['fp']} -> ${s.fp}');
      if (s.bd != (want['bd'] as int)) diffs.add('$key: block-diagram ${want['bd']} -> ${s.bd}');
      final have = s.blocks.toSet();
      final wantBlocks = ((want['blocks'] as List?) ?? const []).cast<String>().toSet();
      final lost = wantBlocks.difference(have).toList()..sort();
      final gained = have.difference(wantBlocks).toList()..sort();
      if (lost.isNotEmpty) diffs.add('$key: lost blocks $lost');
      if (gained.isNotEmpty) diffs.add('$key: gained blocks $gained');
    }
    for (final key in byKey.keys) {
      if (!snap.containsKey(key)) diffs.add('$key: corpus VI not in the snapshot');
    }
    expect(
      diffs,
      isEmpty,
      reason:
          'per-VI features diverged from the snapshot (${diffs.length} file(s)):\n'
          '${diffs.take(20).join('\n')}\n'
          'If intended, regenerate and commit the diff: $snapshotRegenCommand',
    );
  });
}
