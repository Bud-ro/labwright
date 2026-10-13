import 'dart:io';
import 'dart:isolate';

import 'corpus/laws.dart';
import 'corpus_dirs.dart';

/// Parses the VIs at [paths], applies every catalogued law to each, and replies with the pass or
/// with why it failed.
void main(List<String> paths, SendPort reply) {
  final results = {for (final law in corpusLaws) law.name: <Object?>[]};
  final lawMicros = {for (final law in corpusLaws) law.name: 0};
  var parseMicros = 0;
  final clock = Stopwatch()..start();
  for (final path in paths) {
    final vi = parseCorpusVi(File(path));
    parseMicros += clock.elapsedMicroseconds;
    clock.reset();
    for (final law in corpusLaws) {
      try {
        results[law.name]!.add(law.apply(vi));
      } catch (error, stack) {
        reply.send(['the ${law.name} law threw on $path: $error\n$stack']);
        return;
      }
      lawMicros[law.name] = lawMicros[law.name]! + clock.elapsedMicroseconds;
      clock.reset();
    }
  }
  reply.send([results, parseMicros, lawMicros]);
}
