import 'dart:io';

import 'corpus_indexing.dart';

/// Run: `dart run tool/index_corpus.dart <corpus-dir> [--check] [--source <name> ...]`
///
/// Writes the `index.json` of every vendored source under `<corpus-dir>/sources/` (or of the
/// directory itself when it has no `sources/`), or only of the named sources. With `--check`,
/// writes nothing and exits 1 when any index is missing or differs from a fresh one.
Future<void> main(List<String> args) async {
  final rest = [...args];
  var check = false;
  final sources = <String>[];
  String? dir;
  while (rest.isNotEmpty) {
    final arg = rest.removeAt(0);
    switch (arg) {
      case '--check':
        check = true;
      case '--source':
        if (rest.isEmpty) return _usage();
        sources.add(rest.removeAt(0));
      case '--help' || '-h':
        return _usage();
      default:
        if (dir != null) return _usage();
        dir = arg;
    }
  }
  if (dir == null) return _usage();
  final corpus = Directory(dir).absolute;
  if (!corpus.existsSync()) {
    stderr.writeln('no such directory: ${corpus.path}');
    exitCode = 2;
    return;
  }
  final roots = sources.isEmpty ? null : [for (final name in sources) Directory('${corpus.path}/sources/$name')];
  for (final root in roots ?? const <Directory>[]) {
    if (!root.existsSync()) {
      stderr.writeln('no such source: ${root.path}');
      exitCode = 2;
      return;
    }
  }
  final watch = Stopwatch()..start();
  final states = await updateCorpusIndexes(
    corpus,
    roots: roots,
    check: check,
    onDone: (file, state) {
      final relative = file.path.substring(corpus.path.length + 1);
      stdout.writeln('${state.name.padRight(9)} $relative');
    },
  );
  final counts = <IndexFileState, int>{};
  for (final state in states.values) {
    counts.update(state, (n) => n + 1, ifAbsent: () => 1);
  }
  stdout.writeln(
    '${states.length} index files in ${watch.elapsed.inSeconds}s: '
    '${[for (final MapEntry(:key, :value) in counts.entries) '$value ${key.name}'].join(', ')}',
  );
  if (check && states.values.any((state) => state != IndexFileState.unchanged)) exitCode = 1;
}

void _usage() {
  stderr.writeln('usage: dart run tool/index_corpus.dart <corpus-dir> [--check] [--source <name> ...]');
  exitCode = 2;
}
