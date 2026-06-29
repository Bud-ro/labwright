// Investigative: decode the type table. Each named type is bounded by 0x6259ecd3
// stamps; within a type-def record the type's own name and its fields' names are
// cited by u32 pool rel-offset. Scan each record for u32 values (at every byte
// phase, since records are byte-packed) that resolve to a pool string, in byte
// order, to read off [type name, field names...]. Run: dart run tool/typedef.dart [name]
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
  // pool rel-offset -> name (unique starts only, to reduce coincidence)
  final rel = <int, String>{};
  final dup = <int>{};
  for (final s in binaryStrings(body, minLength: 2)) {
    if (s.offset < rr) continue;
    final r = s.offset - rr;
    if (rel.containsKey(r)) dup.add(r);
    rel[r] = s.text;
  }

  const magic = 0x6259ecd3;
  final offs = <int>[];
  for (var i = 0; i + 4 <= rr; i++) {
    if (bd.getUint32(i, Endian.little) == magic) offs.add(i);
  }

  for (var k = 0; k < offs.length; k++) {
    final start = offs[k] + 4;
    final end = k + 1 < offs.length ? offs[k + 1] : rr;
    if (end - start > 2200) {
      stdout.writeln('type[$k] @${offs[k]} size=${end - start}  (object data — skipped)');
      continue;
    }
    // Field defs are [u32 nameRef][u16,u16 descriptor]. The dominant descriptor is
    // 0x004d0018 (= u16 0x18,0x4d). Find each descriptor occurrence and read the
    // u32 4 bytes before it as the field name-ref (resolve against the pool).
    const desc = 0x004d0018;
    final fields = <String>[];
    var descCount = 0;
    for (var i = start; i + 4 <= end; i++) {
      if (bd.getUint32(i, Endian.little) != desc) continue;
      descCount++;
      if (i - 4 < start) { fields.add('?'); continue; }
      final nref = bd.getUint32(i - 4, Endian.little);
      fields.add(rel[nref] ?? '#$nref');
    }
    stdout.writeln('type[$k] @${offs[k]} size=${end - start} descs=$descCount: '
        '${fields.join(" | ")}');
  }
}
