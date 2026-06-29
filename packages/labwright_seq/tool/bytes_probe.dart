// Investigative: locate KNOWN values (from the content-exact OutputVoltage XML
// twin) inside the inflated binary body and dump their byte framing, so the
// leaf-property grammar (name / type / flags / value layout) can be read off
// directly against ground truth. Byte-packed records defeat a u32-word scan, so
// this works in raw bytes around known anchors.
//
// Run: dart run tool/bytes_probe.dart <name> [f64:<double> | str:<text> | hex:<bytes>]...
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

String _ascii(Uint8List b, int from, int len) {
  final sb = StringBuffer();
  for (var i = from; i < from + len && i < b.length; i++) {
    final c = b[i];
    sb.write(c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '.');
  }
  return sb.toString();
}

void _dumpContext(Uint8List body, int at, int rr, {int before = 24, int after = 40}) {
  final start = (at - before).clamp(0, body.length);
  final end = (at + after).clamp(0, body.length);
  final bd = ByteData.sublistView(body);
  for (var off = start; off < end; off += 4) {
    if (off + 4 > body.length) break;
    final u32 = bd.getUint32(off, Endian.little);
    final lo = u32 & 0xffff, hi = (u32 >> 16) & 0xffff;
    final mark = off == at ? '  <== HIT' : (off <= at && at < off + 4 ? '  <== HIT(+${at - off})' : '');
    final delta = off - at;
    stdout.writeln('  @${off.toString().padLeft(6)} (${delta >= 0 ? '+' : ''}$delta)  '
        'u32=${u32.toString().padLeft(11)}  u16=($lo,$hi)  '
        '"${_ascii(body, off, 4)}"$mark');
  }
  stdout.writeln('  (record-region length rr=$rr; this hit is in the '
      '${at < rr ? 'RECORD' : 'STRING'} region, rel=${at - rr})');
}

void main(List<String> args) {
  final which = args.isEmpty ? 'OutputVoltage' : args[0];
  final f = _find(which);
  if (f == null) { stderr.writeln('not found: $which'); exit(1); }
  final raw = Uint8List.fromList(f.readAsBytesSync());
  final body = inflateBinaryBody(raw)!;
  final rr = analyzeBinaryBody(raw)!.recordRegionLength;
  stdout.writeln('$which: inflated=${body.length} rr=$rr');

  for (final spec in args.skip(1)) {
    final ci = spec.indexOf(':');
    final kind = spec.substring(0, ci);
    final arg = spec.substring(ci + 1);
    final needle = <int>[];
    String label;
    if (kind == 'dump') {
      final dash = arg.indexOf('-');
      final from = int.parse(arg.substring(0, dash));
      final to = int.parse(arg.substring(dash + 1));
      stdout.writeln('\n===== hex dump @$from..$to (rr=$rr) =====');
      for (var off = from; off < to && off < body.length; off += 16) {
        final hex = StringBuffer();
        for (var i = off; i < off + 16 && i < to && i < body.length; i++) {
          hex.write(body[i].toRadixString(16).padLeft(2, '0'));
          hex.write(i % 2 == 1 ? ' ' : '');
        }
        stdout.writeln('  @${off.toString().padLeft(6)}: ${hex.toString().padRight(42)}'
            '|${_ascii(body, off, 16)}|');
      }
      continue;
    }
    if (kind == 'f64') {
      final bd = ByteData(8)..setFloat64(0, double.parse(arg), Endian.little);
      needle.addAll(bd.buffer.asUint8List());
      label = 'f64=$arg';
    } else if (kind == 'str') {
      needle.addAll(arg.codeUnits);
      label = 'str="$arg"';
    } else if (kind == 'hex') {
      for (var i = 0; i < arg.length; i += 2) {
        needle.add(int.parse(arg.substring(i, i + 2), radix: 16));
      }
      label = 'hex=$arg';
    } else {
      stderr.writeln('unknown spec: $spec');
      continue;
    }
    stdout.writeln('\n===== $label  (${needle.length} bytes) =====');
    var found = 0;
    for (var i = 0; i + needle.length <= body.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (body[i + j] != needle[j]) { ok = false; break; }
      }
      if (!ok) continue;
      found++;
      stdout.writeln('--- occurrence $found at @$i ---');
      _dumpContext(body, i, rr);
      if (found >= 6) { stdout.writeln('  (more occurrences elided)'); break; }
    }
    if (found == 0) stdout.writeln('  NOT FOUND');
  }
}
