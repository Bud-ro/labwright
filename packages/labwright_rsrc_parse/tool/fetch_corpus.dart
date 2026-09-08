import 'dart:convert';
import 'dart:io';

import 'corpus_base.dart';

/// Usage:
///   dart run tool/fetch_corpus.dart [destRoot]
Future<void> main(List<String> args) async {
  final catalog = findCatalog('sources.json');
  final dest = args.firstOrNull ?? '${catalog.parent.path}/vi';
  final sources = (jsonDecode(catalog.readAsStringSync())['sources'] as List).cast<Map<String, dynamic>>();
  Directory(dest).createSync(recursive: true);
  stdout.writeln('corpus dest: $dest  (${sources.length} sources from ${catalog.path})');
  final tally = await fetchSources(sources, dest, const ['.vi']);
  stdout.writeln('done: $tally; corpus now holds ${countFiles(Directory(dest), '.vi')} .vi at $dest');
  if (tally.failed > 0) exitCode = 1;
}
