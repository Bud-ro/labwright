// Oracle-driven alignment: take every Num leaf from the XML twin (its exact f64
// value + DFS position), locate that f64 in the binary object data, and report
// byte-position vs DFS index. If object records are emitted in tree order the two
// are monotonic, and consecutive deltas reveal the per-record stride — turning the
// byte-packed walk into a checkable problem. Run: dart run tool/align_probe.dart [name]
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

File? _find(String which, String suffix) {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final root in ['${d.path}/packages/labwright_seq/corpus/seq/rosetta', '${d.path}/corpus/seq/rosetta']) {
      final c = File('$root/$which$suffix');
      if (c.existsSync()) return c;
    }
    d = d.parent;
  }
  return null;
}

void main(List<String> args) {
  final which = args.isEmpty ? 'OutputVoltage' : args[0];
  final binF = _find(which, '_BIN.seq') ?? _find(which, '_labview_BIN.seq');
  final xmlF = _find(which, '_XML.seq') ?? _find(which, '_python_XML.seq');
  if (binF == null || xmlF == null) { stderr.writeln('missing pair'); exit(1); }
  final body = inflateBinaryBody(Uint8List.fromList(binF.readAsBytesSync()))!;
  final rr = analyzeBinaryBody(Uint8List.fromList(binF.readAsBytesSync()))!.recordRegionLength;

  // DFS the XML, collecting Num leaves: (dfsIndex, name, value).
  final sf = parseSeqFile(Uint8List.fromList(xmlF.readAsBytesSync()));
  final nums = <(int, String, double)>[];
  var dfs = 0;
  void walk(SeqProperty p) {
    final idx = dfs++;
    if (p.className == 'Num' && p.scalar != null) {
      final v = double.tryParse(p.scalar!.trim());
      if (v != null) nums.add((idx, p.name, v));
    }
    for (final c in p.subProps) {
      walk(c);
    }
    for (final e in p.array ?? const <SeqProperty>[]) {
      walk(e);
    }
  }
  walk(sf.data);

  // find ALL byte positions of an f64 value (sorted ascending).
  List<int> findAll(double v) {
    final needle = ByteData(8)..setFloat64(0, v, Endian.little);
    final nb = needle.buffer.asUint8List();
    final out = <int>[];
    outer:
    for (var i = 0; i + 8 <= body.length; i++) {
      for (var j = 0; j < 8; j++) {
        if (body[i + j] != nb[j]) continue outer;
      }
      out.add(i);
    }
    return out;
  }

  // Anchors = values that are unique BOTH among Num leaves and in the raw bytes
  // (exactly one f64 occurrence). Those are unambiguous tree<->byte fixpoints.
  final freq = <double, int>{};
  for (final (_, _, v) in nums) {
    freq[v] = (freq[v] ?? 0) + 1;
  }
  final rows = <(int, String, double, int)>[]; // dfsIdx, name, val, bytePos
  for (final (idx, name, v) in nums) {
    if (v == 0 || freq[v] != 1) continue;
    final pos = findAll(v);
    if (pos.length == 1) rows.add((idx, name, v, pos.single));
  }
  stdout.writeln('$which: ${nums.length} Num leaves, ${rows.length} unambiguous anchors');
  stdout.writeln('rr=$rr  (object data is the high byte range)\n');

  // sort by byte position; show DFS index alongside to test monotonicity + stride.
  rows.sort((a, b) => a.$4.compareTo(b.$4));
  var prev = -1, prevIdx = -1;
  for (final (idx, name, v, pos) in rows) {
    final dPos = prev < 0 ? 0 : pos - prev;
    final dIdx = prevIdx < 0 ? 0 : idx - prevIdx;
    final mono = dIdx > 0 ? '' : '  <== DFS NOT monotonic';
    stdout.writeln('  @${pos.toString().padLeft(6)} (+${dPos.toString().padLeft(4)})  '
        'dfs=${idx.toString().padLeft(3)} (+${dIdx.toString().padLeft(3)})  '
        '$name=$v$mono');
    prev = pos;
    prevIdx = idx;
  }
}
