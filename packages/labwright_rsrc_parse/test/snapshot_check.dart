import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Exact-match gate for corpus-derived metrics against the `sections` map of
/// the committed `corpus/snapshot.json`.
///
/// Every value here is a MEASUREMENT over the pinned corpus (counts, raw byte
/// totals, census numerators/denominators) — deterministic, so it is asserted
/// EXACTLY. Any change, up or down, fails with a per-key diff until the
/// snapshot is regenerated ([snapshotRegenCommand]) and the new numbers are
/// reviewed as part of the diff. Format LAWS (X == Y between computed
/// quantities, zero-fabrication sweeps) stay as ordinary assertions in the
/// tests; only measurements live in the snapshot.
const snapshotRegenCommand = 'dart run packages/labwright_rsrc_parse/tool/snapshot.dart';

/// Set by the regen tool to a fragment directory: metrics are recorded there
/// instead of asserted, and the tool merges them into `corpus/snapshot.json`.
final String? _updateDir = Platform.environment['LABWRIGHT_SNAPSHOT_UPDATE'];

/// True while the regen tool is re-measuring (fragments being recorded
/// instead of asserted).
bool get snapshotUpdateMode => _updateDir != null;

Map<String, Object?>? _sectionsCache;

Map<String, Object?> _sections() {
  if (_sectionsCache != null) return _sectionsCache!;
  final file = corpusSnapshotFile();
  if (!file.existsSync()) {
    fail('corpus snapshot missing (${file.path}) — run: $snapshotRegenCommand');
  }
  final root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return _sectionsCache = ((root['sections'] as Map?) ?? const <String, Object?>{}).cast<String, Object?>();
}

/// Asserts [actual] equals snapshot section [section] exactly — same key set,
/// same value per key. Under the regen tool it records [actual] instead.
void expectCorpusSnapshot(String section, Map<String, int> actual) {
  final dir = _updateDir;
  if (dir != null) {
    final sorted = {for (final k in actual.keys.toList()..sort()) k: actual[k]};
    File('$dir/$section.json').writeAsStringSync(jsonEncode(sorted));
    return;
  }
  final want = (_sections()[section] as Map?)?.cast<String, Object?>();
  if (want == null) {
    fail('corpus snapshot section "$section" missing — run: $snapshotRegenCommand');
  }
  final keys = {...want.keys, ...actual.keys}.toList()..sort();
  final diffs = <String>[
    for (final k in keys)
      if (want[k] != actual[k])
        '  $k: actual ${actual.containsKey(k) ? actual[k] : '(absent)'}'
            ' vs snapshot ${want.containsKey(k) ? want[k] : '(absent)'}',
  ];
  if (diffs.isNotEmpty) {
    fail(
      'corpus metrics diverged from snapshot section "$section" '
      '(${diffs.length}/${keys.length} keys):\n${diffs.join('\n')}\n'
      'If intended, regenerate and commit the diff: $snapshotRegenCommand',
    );
  }
}
