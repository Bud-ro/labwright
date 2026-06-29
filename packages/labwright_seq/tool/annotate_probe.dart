// Investigative: full annotated dump of a binary TOF1 record region, marking
// type-def boundaries (0x6259ecd3) and resolving every word that hits a name
// (string-region rel-offset). Used to derive the object-record grammar against
// the Rosetta XML twin. Run: dart run tool/annotate_probe.dart <name> [from] [to]
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

int _u32(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

void main(List<String> args) {
  final which = args.isEmpty ? 'NIScope' : args[0];
  var d = Directory.current;
  File? f;
  // Resolve both naming schemes: `_BIN.seq` (content-exact twin) and
  // `_labview_BIN.seq` (structural twin), under either layout root.
  for (var i = 0; i < 8 && f == null; i++) {
    for (final root in ['${d.path}/packages/labwright_seq/corpus/seq/rosetta', '${d.path}/corpus/seq/rosetta']) {
      for (final suf in ['_BIN.seq', '_labview_BIN.seq']) {
        final c = File('$root/$which$suf');
        if (c.existsSync()) { f = c; break; }
      }
      if (f != null) break;
    }
    d = d.parent;
  }
  if (f == null) { stderr.writeln('not found'); exit(1); }
  final raw = Uint8List.fromList(f.readAsBytesSync());
  final body = inflateBinaryBody(raw)!;
  final rr = analyzeBinaryBody(raw)!.recordRegionLength;
  final rel = <int, String>{
    for (final s in binaryStrings(body, minLength: 1))
      if (s.offset >= rr) s.offset - rr: s.text,
  };
  final bd = ByteData.sublistView(body);
  final wc = rr ~/ 4;
  final fromW = args.length > 1 ? int.parse(args[1]) : 0;
  final toW = args.length > 2 ? int.parse(args[2]) : wc;
  for (var w = fromW; w < toW && w < wc; w++) {
    final v = _u32(body, w * 4);
    final byte = w * 4;
    final ann = StringBuffer();
    if (v == 0x6259ecd3) ann.write('  <<< TYPEDEF-MAGIC');
    final nm = rel[v];
    if (nm != null && v != 0) ann.write('  name[$v]="$nm"');
    // f64 interpretation if this and next word form a clean double
    if (w + 1 < wc && v == 0) {
      final dv = bd.getFloat64(byte, Endian.little);
      if (dv.isFinite && dv != 0 && dv.abs() > 1e-9 && dv.abs() < 1e12) {
        ann.write('  f64=$dv');
      }
    }
    // u16 pair interpretation
    final lo = v & 0xffff, hi = (v >> 16) & 0xffff;
    if (v != 0 && hi != 0 && lo < 0x200 && hi < 0x200) ann.write('  u16=($lo,$hi)');
    stdout.writeln('${w.toString().padLeft(4)} @${byte.toString().padLeft(6)}: '
        '${v.toString().padLeft(11)} 0x${v.toRadixString(16).padLeft(8, '0')}$ann');
  }
}
