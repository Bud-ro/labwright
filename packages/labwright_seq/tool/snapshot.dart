import 'dart:io';

import '../../../tool/corpus.dart';
import '../test/corpus_snapshot.dart';

void main() {
  final lines = corpusSnapshotLines();
  File('${repoRoot().path}/packages/labwright_seq/$corpusSnapshotPath').writeAsStringSync(corpusSnapshotText(lines));
  stdout.writeln('snapshot: ${lines.length} .seq files');
}
