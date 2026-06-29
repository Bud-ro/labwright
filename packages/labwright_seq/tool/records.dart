// Investigative: split the record region on the 0xffffffff marker and inspect each
// chunk, to test whether 0xffffffff delimits per-object records and to read off the
// object-record framing. For each chunk: length, leading u32 words (read from the
// chunk start, which is 4-aligned to the marker), any word resolving to a pool name
// (rel-offset), and any clean inline f64. Run: dart run tool/records.dart [name] [from] [count]
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

File? _find(String which) {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final root in ['${d.path}/packages/labwright_seq/corpus/seq/rosetta', '${d.path}/corpus/seq/rosetta']) {
      for (final suf in ['_BIN.seq', '_labview_BIN.seq']) {
        final c = File('$root/$which$suf');
        if (c.existsSync()) return c;
      }
    }
    d = d.parent;
  }
  return null;
}

void main(List<String> args) {
  final which = args.isEmpty ? 'OutputVoltage' : args[0];
  final from = args.length > 1 ? int.parse(args[1]) : 0;
  final count = args.length > 2 ? int.parse(args[2]) : 30;
  final f = _find(which);
  if (f == null) { stderr.writeln('not found: $which'); exit(1); }
  final raw = Uint8List.fromList(f.readAsBytesSync());
  final body = inflateBinaryBody(raw)!;
  final rr = analyzeBinaryBody(raw)!.recordRegionLength;
  final bd = ByteData.sublistView(body);
  final rel = <int, String>{
    for (final s in binaryStrings(body, minLength: 2))
      if (s.offset >= rr) s.offset - rr: s.text,
  };

  // marker positions (4 consecutive 0xff)
  final marks = <int>[];
  for (var i = 0; i + 4 <= rr; i++) {
    if (body[i] == 0xff && body[i + 1] == 0xff && body[i + 2] == 0xff && body[i + 3] == 0xff) {
      marks.add(i);
    }
  }
  stdout.writeln('$which: rr=$rr  ${marks.length} 0xffffffff markers\n');

  for (var k = from; k < marks.length && k < from + count; k++) {
    final start = marks[k] + 4; // chunk begins after the marker
    final end = k + 1 < marks.length ? marks[k + 1] : rr;
    final len = end - start;
    // header model (working hypothesis): [u32 w0][u32 objectID][u16 t1][u16 t2]...
    final w0 = len >= 4 ? bd.getUint32(start, Endian.little) : -1;
    final id = len >= 8 ? bd.getUint32(start + 4, Endian.little) : -1;
    final t1 = len >= 10 ? bd.getUint16(start + 8, Endian.little) : -1;
    final t2 = len >= 12 ? bd.getUint16(start + 10, Endian.little) : -1;
    final words = StringBuffer();
    final names = <String>[];
    for (var w = 0; w * 4 + 4 <= len && w < 12; w++) {
      final v = bd.getUint32(start + w * 4, Endian.little);
      words.write('${v.toString().padLeft(10)} ');
      final n = rel[v];
      if (n != null && v > 8 && n.length >= 3) names.add('w$w="$n"');
    }
    // clean inline f64s in the chunk
    final f64s = <String>[];
    for (var o = 0; o + 8 <= len; o++) {
      if (bd.getUint32(start + o, Endian.little) != 0) continue;
      final dv = bd.getFloat64(start + o, Endian.little);
      if (dv.isFinite && dv != 0 && dv.abs() > 1e-6 && dv.abs() < 1e12) {
        f64s.add('@$o=$dv');
      }
    }
    stdout.writeln('rec[$k] @${marks[k].toString().padLeft(6)} len=${len.toString().padLeft(4)}  '
        'w0=$w0 id=$id desc=(0x${t1.toRadixString(16)},0x${t2.toRadixString(16)})');
    stdout.writeln('        words: $words');
    if (names.isNotEmpty) stdout.writeln('        names: ${names.join("  ")}');
    if (f64s.isNotEmpty) stdout.writeln('        f64:   ${f64s.join("  ")}');
  }
}
