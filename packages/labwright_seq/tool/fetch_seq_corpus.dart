import 'dart:convert';
import 'dart:io';

import '../../labwright_rsrc_parse/tool/corpus_base.dart';

/// Usage:
///   dart run tool/fetch_seq_corpus.dart [destRoot]
Future<void> main(List<String> args) async {
  final catalog = findCatalog('seq-sources.json');
  final dest = args.firstOrNull ?? '${catalog.parent.path}/seq';
  final entries = jsonDecode(catalog.readAsStringSync()) as Map<String, dynamic>;
  final sources = (entries['sources'] as List).cast<Map<String, dynamic>>();
  final rosetta = [
    for (final twin in (entries['rosetta'] as List).cast<Map<String, dynamic>>())
      (
        file: twin['file'] as String,
        repo: twin['repo'] as String,
        commit: twin['commit'] as String,
        path: twin['path'] as String,
        sha256: twin['sha256'] as String,
      ),
  ];
  Directory(dest).createSync(recursive: true);
  stdout.writeln('seq corpus dest: $dest  (${sources.length} sources from ${catalog.path})');
  final tally = await fetchSources(sources, dest, const ['.seq', '.ini', '.cfg', '.tsw', '.tpj']);
  for (final twin in rosetta) {
    final file = File('$dest/rosetta/${twin.file}');
    if (fileMatches(file, twin.sha256)) continue;
    stdout.writeln('fetch rosetta/${twin.file} from ${twin.repo} @ ${twin.commit.substring(0, 12)}');
    final ok = await fetchRawFile(twin.repo, twin.commit, twin.path, twin.sha256, file);
    if (ok) {
      tally.fetched++;
    } else {
      tally.failed++;
    }
  }
  stdout.writeln('done: $tally; corpus now holds ${countFiles(Directory(dest), '.seq')} .seq at $dest');
  if (tally.failed > 0) exitCode = 1;
}
