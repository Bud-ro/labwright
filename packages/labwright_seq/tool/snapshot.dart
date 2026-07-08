import 'dart:convert';
import 'dart:io';

/// Regenerates the committed corpus metrics snapshot (`corpus/snapshot.json`).
///
/// The corpus tests measure everything (single source of truth — the exact
/// code that asserts is the code that measures); this tool re-runs them with
/// `LABWRIGHT_SNAPSHOT_UPDATE` pointed at a fragment directory, where each
/// `expectCorpusSnapshot` call site records its section instead of asserting.
/// The fragments are then merged over the existing snapshot and written back
/// deterministically (sorted sections, sorted keys, one key per line) so
/// regeneration diffs are minimal and reviewable.
///
/// Run: `dart run packages/labwright_seq/tool/snapshot.dart`
/// Requires the fetched corpus (tool/fetch_seq_corpus.dart). Aborts without
/// writing when the test run fails — laws must hold before numbers are pinned.

/// The corpus test files that own snapshot sections.
const _sectionTests = [
  'test/corpus_seq_test.dart',
  'test/binary_sweep_test.dart',
  'test/binary_writer_corpus_test.dart',
  'test/export_corpus_test.dart',
];

void main() {
  final pkgRoot = _packageRoot();
  if (pkgRoot == null) {
    stderr.writeln('error: could not locate corpus/seq-sources.json (run from within the repo)');
    exitCode = 1;
    return;
  }
  if (!Directory('$pkgRoot/corpus/seq').existsSync()) {
    stderr.writeln('error: corpus not fetched — run tool/fetch_seq_corpus.dart first');
    exitCode = 1;
    return;
  }

  final fragments = Directory.systemTemp.createTempSync('lw_seq_snapshot_');
  try {
    stdout.writeln('re-measuring: dart test -t corpus ${_sectionTests.join(' ')}');
    final result = Process.runSync(
      'dart',
      [
        'test',
        '-t',
        'corpus',
        ..._sectionTests,
      ],
      workingDirectory: pkgRoot,
      environment: {'LABWRIGHT_SNAPSHOT_UPDATE': fragments.path},
    );
    stdout.write(result.stdout);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      stderr.writeln('test run failed (exit ${result.exitCode}) — snapshot NOT written');
      exitCode = result.exitCode;
      return;
    }

    final out = File('$pkgRoot/corpus/snapshot.json');
    final sections = <String, Map<String, Object?>>{};
    if (out.existsSync()) {
      final old = jsonDecode(out.readAsStringSync()) as Map<String, dynamic>;
      (old['sections'] as Map?)?.forEach((k, v) => sections[k as String] = (v as Map).cast<String, Object?>());
    }
    var fresh = 0;
    for (final f in fragments.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
      if (!f.path.endsWith('.json')) continue;
      final section = f.uri.pathSegments.last.replaceAll('.json', '');
      sections[section] = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
      fresh++;
    }
    if (fresh == 0) {
      stderr.writeln('no snapshot fragments produced — snapshot NOT written');
      exitCode = 1;
      return;
    }

    final doc = {
      'generatedBy': 'packages/labwright_seq/tool/snapshot.dart',
      'note':
          'Exact corpus metrics (counts and raw byte totals) measured by the corpus '
          'tests over the pinned TestStand corpus; asserted with exact equality by '
          'test/snapshot_check.dart. Regenerate with the tool above and review the '
          'numbers as part of the PR diff.',
      'sections': {
        for (final k in sections.keys.toList()..sort())
          k: {
            for (final key in sections[k]!.keys.toList()..sort()) key: sections[k]![key],
          },
      },
    };
    out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
    stdout.writeln('wrote ${out.path} ($fresh section(s) refreshed, ${sections.length} total)');
  } finally {
    fragments.deleteSync(recursive: true);
  }
}

/// Walks up from CWD looking for this package (same resolution as the tests).
String? _packageRoot() {
  const pkgRel = 'packages/labwright_seq';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final base in ['${dir.path}/$pkgRel', dir.path]) {
      if (File('$base/corpus/seq-sources.json').existsSync()) return base;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
