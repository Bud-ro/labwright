// Investigative: does the per-file constant at body byte 24 recur as an
// object-header magic across the Rosetta binaries?
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/src/seq_binary.dart';

int _u32(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

void main() {
  for (final w in ['NIScope', 'NIDmm', 'NIFgen']) {
    var d = Directory.current;
    File? f;
    for (var i = 0; i < 8; i++) {
      final c = File('${d.path}/packages/labwright_seq/corpus/seq/rosetta/${w}_labview_BIN.seq');
      if (c.existsSync()) { f = c; break; }
      d = d.parent;
    }
    if (f == null) continue;
    final raw = Uint8List.fromList(f.readAsBytesSync());
    final body = inflateBinaryBody(raw);
    final layout = analyzeBinaryBody(raw);
    if (body == null || layout == null) continue;
    final rr = layout.recordRegionLength;
    final magic = _u32(body, 24);
    var count = 0;
    var last = -1;
    final gaps = <int>{};
    for (var i = 0; i + 3 < rr; i++) {
      if (_u32(body, i) == magic) {
        count++;
        if (last >= 0) gaps.add(i - last);
        last = i;
      }
    }
    final gl = gaps.toList()..sort();
    stdout.writeln('$w: magic=0x${magic.toRadixString(16)} x$count in record region '
        '(${rr ~/ 4} words); distinct gaps=${gl.length}'
        '${gl.isEmpty ? '' : ' min=${gl.first} max=${gl.last}'}');
  }
}
