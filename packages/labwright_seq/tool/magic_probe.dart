// Investigative: byte offsets + gaps of the type-def marker 0x6259ecd3 across
// the Rosetta binaries (the marker is byte-packed, not u32-aligned).
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/src/seq_binary.dart';

int _u32(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

void main(List<String> args) {
  final names = args.isEmpty ? ['NIScope', 'NIDmm', 'NIFgen'] : args;
  for (final w in names) {
    var d = Directory.current;
    File? f;
    for (var i = 0; i < 8 && f == null; i++) {
      for (final root in ['${d.path}/packages/labwright_seq/corpus/seq/rosetta', '${d.path}/corpus/seq/rosetta']) {
        for (final suf in ['_BIN.seq', '_labview_BIN.seq']) {
          final c = File('$root/$w$suf');
          if (c.existsSync()) { f = c; break; }
        }
        if (f != null) break;
      }
      d = d.parent;
    }
    if (f == null) continue;
    final raw = Uint8List.fromList(f.readAsBytesSync());
    final body = inflateBinaryBody(raw);
    final layout = analyzeBinaryBody(raw);
    if (body == null || layout == null) continue;
    final rr = layout.recordRegionLength;
    const magic = 0x6259ecd3;
    final offs = <int>[];
    for (var i = 0; i + 3 < rr; i++) {
      if (_u32(body, i) == magic) offs.add(i);
    }
    stdout.writeln('$w: rr=$rr  ${offs.length} magics');
    for (var k = 0; k < offs.length; k++) {
      final gap = k == 0 ? offs[0] : offs[k] - offs[k - 1];
      final aligned = offs[k] % 4 == 0 ? 'u32' : 'b${offs[k] % 4}';
      stdout.writeln('  @${offs[k].toString().padLeft(6)}  gap=${gap.toString().padLeft(6)}  $aligned');
    }
  }
}
