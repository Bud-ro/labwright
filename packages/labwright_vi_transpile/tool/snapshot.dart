import 'dart:io';

import '../../../tool/corpus.dart';
import '../test/corpus_snapshot.dart';

Future<void> main() async {
  final lines = (await corpusSweep()).lines;
  File(
    '${repoRoot().path}/packages/labwright_vi_transpile/$corpusSnapshotPath',
  ).writeAsStringSync(corpusSnapshotText(lines));
  stdout.writeln('snapshot: ${lines.length} VIs');
}
