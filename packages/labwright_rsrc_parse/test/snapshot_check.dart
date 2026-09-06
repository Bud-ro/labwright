import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'corpus_dirs.dart';

const snapshotRegenCommand = 'dart run packages/labwright_rsrc_parse/tool/snapshot.dart';

final String? _updateDir = Platform.environment['LABWRIGHT_SNAPSHOT_UPDATE'];

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
