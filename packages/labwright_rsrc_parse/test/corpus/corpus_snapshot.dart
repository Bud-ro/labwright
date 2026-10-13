import 'dart:convert';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

typedef _Snap = ({bool error, int fp, int bd, List<String> blocks});

typedef _Want = ({bool error, int fp, int bd, Set<String> blocks});

/// The [_Snap] fields in order.
List<Object?> _summarizeVi(CorpusVi vi) {
  try {
    final blocks = parseVi(vi.bytes).blocks.toSet().toList()..sort();
    final m = vi.model;
    if (m == null) throw vi.error!;
    final fp = m.frontPanelDiagrams.fold(0, (a, b) => a + b.objects.length);
    final bd = m.blockDiagrams.fold(0, (a, b) => a + b.objects.length);
    return [false, fp, bd, blocks];
  } catch (_) {
    return [true, 0, 0, const <String>[]];
  }
}

_Snap _snapOf(List<Object?> row) =>
    (error: row[0] as bool, fp: row[1] as int, bd: row[2] as int, blocks: (row[3] as List).cast<String>());

const corpusSnapshotLaw = CorpusLaw('corpus_snapshot', _summarizeVi);

void corpusSnapshotTests() {
  final all = corpusVis.files;
  final snapFile = corpusSnapshotFile();

  final root = '${corpusViDir.path}/';
  final byKey = {for (final f in all) f.path.substring(root.length).replaceAll('\\', '/'): f.path};
  final snapJson = jsonDecode(snapFile.readAsStringSync()) as Map<String, dynamic>;
  final snap = <String, _Want>{};
  for (final group in (snapJson['groups'] as List).cast<Map<String, dynamic>>()) {
    final blocks = (group['blocks'] as List).cast<String>().toSet();
    for (final file in (group['files'] as List).cast<Map<String, dynamic>>()) {
      snap[file['name'] as String] = (error: false, fp: file['fp'] as int, bd: file['bd'] as int, blocks: blocks);
    }
  }
  for (final failure in (snapJson['errors'] as List).cast<Map<String, dynamic>>()) {
    snap[failure['name'] as String] = (error: true, fp: 0, bd: 0, blocks: const <String>{});
  }

  test('every VI keeps EXACTLY its snapshotted front-panel/block-diagram counts and block set', () async {
    final rows = await corpusSnapshotLaw.results;
    final byPath = {for (var i = 0; i < all.length; i++) all[i].path: _snapOf(rows[i])};
    final diffs = <String>[];
    for (final MapEntry(key: key, value: want) in snap.entries) {
      final s = byPath[byKey[key]];
      if (s == null) continue;
      if (want.error) {
        if (!s.error) diffs.add('$key: now decodes (was a snapshotted decode error)');
        continue;
      }
      if (s.error) {
        diffs.add('$key: now throws on decode (was decodable)');
        continue;
      }
      if (s.fp != want.fp) diffs.add('$key: front-panel ${want.fp} -> ${s.fp}');
      if (s.bd != want.bd) diffs.add('$key: block-diagram ${want.bd} -> ${s.bd}');
      final have = s.blocks.toSet();
      final lost = want.blocks.difference(have).toList()..sort();
      final gained = have.difference(want.blocks).toList()..sort();
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
