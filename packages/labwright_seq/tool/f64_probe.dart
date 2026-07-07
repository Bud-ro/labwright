// Lists the distinct f64 value-slot values in a file's write plan with their
// site counts, and attributes SUBNORMAL values (the i64-read-as-f64
// signature) to the decode pass that claimed them — mutation-target and
// reader-bug scouting.
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> args) {
  final bytes = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final model = parseBinarySeqWriteModel(bytes)!;
  final counts = <double, int>{};
  for (final v in model.f64Values) {
    counts.update(v, (c) => c + 1, ifAbsent: () => 1);
  }
  final entries = counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  for (final e in entries) {
    print('${e.key} x${e.value}');
  }
  final leafRecords = binaryPropertyRecords(bytes);
  for (final e in entries) {
    if (e.key != 0 && e.key.abs() < 2.3e-308) {
      for (final site in model.f64Sites(e.key)) {
        final owners = [
          for (final r in leafRecords)
            if (site >= r.offset && site < r.offset + r.length) '${r.typeName} ${r.name} = ${r.value}',
        ];
        print('subnormal ${e.key} @$site owners=$owners');
      }
    }
  }
}
