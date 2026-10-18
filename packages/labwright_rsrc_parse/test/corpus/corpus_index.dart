import 'dart:io';

import 'package:test/test.dart';

import '../corpus_dirs.dart';

/// The fetched corpus repositories: every directory under `corpus/vi` and `corpus/seq`.
List<Directory> _repositories() => [
  for (final group in ['vi', 'seq'])
    if (Directory('${repoRoot().path}/corpus/$group') case final dir when dir.existsSync())
      ...dir.listSync(followLinks: false).whereType<Directory>(),
]..sort((a, b) => a.path.compareTo(b.path));

void corpusIndexTests() {
  test('every fetched corpus repository passes `index_corpus --check`', () async {
    final repositories = _repositories();
    expect(repositories, isNotEmpty, reason: 'the pinned corpus repositories are fetched');
    for (final repository in repositories) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/index_corpus.dart',
        '--check',
        repository.path,
      ], workingDirectory: repoRoot().path);
      expect(
        result.exitCode,
        0,
        reason:
            '${result.stdout}${result.stderr}'
            'regenerate with `dart run tool/index_corpus.dart ${repository.path}`',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
