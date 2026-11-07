import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

import 'corpus_dirs.dart';

const corpusSnapshotPath = 'test/corpus_snapshot.json';

List<String> corpusSnapshotLines() => [
  for (final file in corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')))
    _line(corpusSeqRelativePath(file.path), file.readAsBytesSync()),
]..sort();

String _line(String name, Uint8List data) {
  final row = <String, Object?>{'name': name, 'format': detectSeqFormat(data).name};
  try {
    final file = parseSeqFile(data);
    final steps = [for (final sequence in file.sequences) ...sequence.steps];
    row.addAll({
      'version': file.header.fileVersion,
      'types': file.types.length,
      'sequences': file.sequences.length,
      'steps': steps.length,
      'modules': steps.where((s) => s.module.adapter != SeqAdapter.none).length,
    });
  } on Exception catch (e) {
    row['error'] = '$e';
  }
  return jsonEncode(row);
}

String corpusSnapshotText(List<String> lines) => '[\n${lines.join(',\n')}\n]\n';
