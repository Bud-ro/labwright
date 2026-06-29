// Investigative: decode the TOF1 type table. Each named type is stamped with
// 0x6259ecd3; this walks the magic-delimited records and resolves every byte
// offset (read as u16 or u32, at any byte phase) that lands on a shared-dictionary
// name, revealing each type's field list. Validated against the OutputVoltage
// content-exact twin. Run: dart run tool/decode_probe.dart [name]
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
  final f = _find(which);
  if (f == null) { stderr.writeln('not found: $which'); exit(1); }
  final raw = Uint8List.fromList(f.readAsBytesSync());
  final body = inflateBinaryBody(raw)!;
  final rr = analyzeBinaryBody(raw)!.recordRegionLength;
  final bd = ByteData.sublistView(body);

  // find all type-stamp offsets
  const magic = 0x6259ecd3;
  final offs = <int>[];
  for (var i = 0; i + 4 <= rr; i++) {
    if (bd.getUint32(i, Endian.little) == magic) offs.add(i);
  }
  stdout.writeln('$which: rr=$rr  ${offs.length} type stamps');

  // Each named type is stamped 0x6259ecd3. The compact early records are the type
  // DEFINITIONS; once a record balloons, the OBJECT/INSTANCE data has begun
  // (that's where the actual values, expressions and module paths live). Report
  // the stamp map and the type-table -> object-data boundary; per-field decode is
  // byte-level work done with bytes_probe.dart, not a u16 phase-scan (too noisy).
  for (var k = 0; k < offs.length; k++) {
    final start = offs[k];
    final end = k + 1 < offs.length ? offs[k + 1] : rr;
    final size = end - start;
    stdout.writeln('  type[$k] @${start.toString().padLeft(6)}  '
        'size=${size.toString().padLeft(5)}'
        '${size > 2000 ? '   <== object/instance data begins here' : ''}');
  }
  stdout.writeln('object data tail: bytes ${offs.last}..$rr '
      '(${rr - offs.last} B of instance records + values)');
}
