// Container probe over the corpus binaries: can any Dart ZLibCodec setting
// (level × strategy × memLevel) reproduce the original deflate bytes; does
// every file end at the zlib adler32 trailer; header length and the
// PMCZ + u32 inflated-size field before the stream.
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

int _adler32(Uint8List data) {
  var a = 1, b = 0;
  for (var i = 0; i < data.length; i++) {
    a = (a + data[i]) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

void main(List<String> args) {
  final root = Directory(args.isEmpty ? 'corpus/seq' : args[0]);
  var binaries = 0, trailerAtEof = 0, pmcz = 0, sizeWord = 0, deflateMatch = 0;
  final headerLens = <int, int>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = Uint8List.fromList(f.readAsBytesSync());
    if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
    final model = parseBinarySeqWriteModel(bytes);
    if (model == null) continue;
    binaries++;
    final streamAt = model.header.length;
    headerLens.update(streamAt, (v) => v + 1, ifAbsent: () => 1);
    final body = inflateBinaryBody(bytes)!;
    final view = ByteData.sublistView(bytes);
    if (bytes.length >= 4 && view.getUint32(bytes.length - 4) == _adler32(body)) {
      trailerAtEof++;
    }
    if (streamAt >= 8 &&
        bytes[streamAt - 8] == 0x50 &&
        bytes[streamAt - 7] == 0x4d &&
        bytes[streamAt - 6] == 0x43 &&
        bytes[streamAt - 5] == 0x5a) {
      pmcz++;
    }
    if (model.headerHasSizeWord) sizeWord++;
    final original = Uint8List.sublistView(bytes, streamAt);
    var matched = false;
    for (var level = 0; level <= 9 && !matched; level++) {
      for (var memLevel = 1; memLevel <= 9 && !matched; memLevel++) {
        for (final strategy in const [0, 1, 2, 3, 4]) {
          final re = ZLibCodec(level: level, memLevel: memLevel, strategy: strategy).encode(body);
          if (re.length != original.length) continue;
          var same = true;
          for (var i = 0; i < re.length; i++) {
            if (re[i] != original[i]) {
              same = false;
              break;
            }
          }
          if (same) {
            matched = true;
            break;
          }
        }
      }
    }
    if (matched) deflateMatch++;
  }
  print(
    'binaries=$binaries deflateMatch=$deflateMatch trailerAtEof=$trailerAtEof '
    'pmcz=$pmcz sizeWord=$sizeWord headerLens=$headerLens',
  );
}
