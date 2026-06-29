// Test the parallel pool-walk hypothesis: do the instance-region pool strings, in
// byte-offset order, match the XML DFS order of node names + string values? If the
// two sequences align, records and the string pool are consumed together in tree
// order (shared-dict names by offset; instance strings by a sequential cursor).
// Run: dart run tool/pool_order.dart [name] [minRel]
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
  final minRel = args.length > 1 ? int.parse(args[1]) : 200;
  final binF = _find(which, '_BIN.seq') ?? _find(which, '_labview_BIN.seq');
  final xmlF = _find(which, '_XML.seq') ?? _find(which, '_python_XML.seq');
  if (binF == null || xmlF == null) { stderr.writeln('missing pair'); exit(1); }
  final raw = Uint8List.fromList(binF.readAsBytesSync());
  final body = inflateBinaryBody(raw)!;
  final rr = analyzeBinaryBody(raw)!.recordRegionLength;

  // pool strings (rel >= minRel) in byte-offset order = the instance string stream
  final pool = <(int, String)>[];
  for (final s in binaryStrings(body, minLength: 1)) {
    if (s.offset >= rr && (s.offset - rr) >= minRel) pool.add((s.offset - rr, s.text));
  }
  pool.sort((a, b) => a.$1.compareTo(b.$1));

  // XML DFS: emit node name then its string scalar value, in order
  final sf = parseSeqFile(Uint8List.fromList(xmlF.readAsBytesSync()));
  final dfs = <String>[];
  void walk(SeqProperty p) {
    dfs.add(p.name);
    if (p.scalar != null && p.scalar!.trim().isNotEmpty && p.className != 'Num' && p.className != 'Bool') {
      dfs.add(p.scalar!.trim());
    }
    for (final c in p.subProps) {
      walk(c);
    }
    for (final e in p.array ?? const <SeqProperty>[]) {
      walk(e);
    }
  }
  walk(sf.data);

  // Align: for each pool string, find it in the DFS stream at/after the last match.
  // Report the matched DFS token + whether order holds (the core hypothesis test).
  var cursor = 0, matched = 0, outOfOrder = 0;
  stdout.writeln('$which: ${pool.length} instance-pool strings (rel>=$minRel), '
      '${dfs.length} DFS tokens\n');
  for (final (rel, text) in pool) {
    var found = -1;
    for (var i = cursor; i < dfs.length; i++) {
      if (dfs[i] == text) { found = i; break; }
    }
    final String mark;
    if (found >= 0) {
      matched++;
      cursor = found + 1;
      mark = 'dfs#$found';
    } else {
      // maybe it appears earlier (out of order) or not at all
      final any = dfs.indexOf(text);
      if (any >= 0) { outOfOrder++; mark = 'OUT-OF-ORDER (dfs#$any < cursor $cursor)'; }
      else { mark = 'NOT IN DFS'; }
    }
    final short = text.length > 42 ? '${text.substring(0, 42)}…' : text;
    stdout.writeln('  rel${rel.toString().padLeft(6)}: "${short.replaceAll('\n', ' ')}"  -> $mark');
  }
  stdout.writeln('\nmatched-in-order=$matched  out-of-order=$outOfOrder  '
      'unmatched=${pool.length - matched - outOfOrder}  '
      '(in-order ratio ${(matched / pool.length * 100).toStringAsFixed(0)}%)');
}
