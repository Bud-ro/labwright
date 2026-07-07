// Writer iteration harness: parse each corpus binary into the write model,
// re-serialize the body, and compare against the original inflated body.
// Prints the first divergence per failing file and the corpus scoreboard.
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> args) {
  final root = Directory(args.isEmpty ? 'corpus/seq' : args[0]);
  var binaries = 0, exact = 0;
  var total = const BinaryWriteScoreboard(
    bodyBytes: 0,
    poolBytes: 0,
    modelBytes: 0,
    structuralBytes: 0,
    copiedBytes: 0,
  );
  final failures = <String>[];
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = Uint8List.fromList(f.readAsBytesSync());
    if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
    final model = parseBinarySeqWriteModel(bytes);
    if (model == null) continue;
    binaries++;
    final body = inflateBinaryBody(bytes)!;
    final written = model.writeBody();
    total = total + model.scoreboard;
    if (written.length == body.length) {
      var diffAt = -1;
      for (var i = 0; i < body.length; i++) {
        if (written[i] != body[i]) {
          diffAt = i;
          break;
        }
      }
      if (diffAt < 0) {
        exact++;
        continue;
      }
      failures.add('${f.path}: first diff at $diffAt (recordRegion=${model.recordRegionLength})');
    } else {
      failures.add('${f.path}: length ${written.length} != ${body.length} (recordRegion=${model.recordRegionLength})');
    }
  }
  print('binaries=$binaries exact=$exact');
  print(total);
  for (final failure in failures.take(20)) {
    print('FAIL $failure');
  }
}
