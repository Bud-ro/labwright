// Oracle-guided position map. For each XML DFS node, anchor its record's byte
// position in the binary by searching the record region for a reference to its
// unique string (its name, or its string/expr/path value) — references are the
// pool rel-offset (offset - rr) encoded LE. Num leaves anchor via their f64.
// Assign greedily in DFS order (object data is tree-ordered), so each node takes
// the earliest candidate at/after the previous node. Inter-node byte deltas then
// expose per-record sizes. Run: dart run tool/guided.dart [name]
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
  final rawBin = Uint8List.fromList(binF.readAsBytesSync());
  final body = inflateBinaryBody(rawBin)!;
  final rr = analyzeBinaryBody(rawBin)!.recordRegionLength;
  final bd = ByteData.sublistView(body);

  // pool: string -> rel-offsets (rel = abs - rr)
  final strToRel = <String, List<int>>{};
  for (final s in binaryStrings(body, minLength: 1)) {
    if (s.offset >= rr) (strToRel[s.text] ??= []).add(s.offset - rr);
  }
  int? uniqueRel(String? t) {
    if (t == null || t.isEmpty) return null;
    final l = strToRel[t];
    return (l != null && l.length == 1) ? l.single : null;
  }

  // byte positions in the record region where a u32 == the pool rel-offset
  // (name/value references are u32 rel-offsets; u16 search was pure noise).
  List<int> findRef(int value) {
    final out = <int>[];
    for (var i = 0; i + 4 <= rr; i++) {
      if (bd.getUint32(i, Endian.little) == value) out.add(i);
    }
    return out;
  }

  List<int> findF64(double v) {
    final nb = (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List();
    final out = <int>[];
    outer:
    for (var i = 0; i + 8 <= rr; i++) {
      for (var j = 0; j < 8; j++) {
        if (body[i + j] != nb[j]) continue outer;
      }
      out.add(i);
    }
    return out;
  }

  // DFS nodes
  final sf = parseSeqFile(Uint8List.fromList(xmlF.readAsBytesSync()));
  final nodes = <(int, SeqProperty)>[];
  var dfs = 0;
  void walk(SeqProperty p) {
    nodes.add((dfs++, p));
    for (final c in p.subProps) {
      walk(c);
    }
    for (final e in p.array ?? const <SeqProperty>[]) {
      walk(e);
    }
  }
  walk(sf.data);

  // Num value frequency: only anchor on an f64 that is unique tree-wide (common
  // values like 1.0/2.0 match too many byte positions to disambiguate cleanly).
  final numFreq = <double, int>{};
  for (final (_, p) in nodes) {
    if (p.className == 'Num' && p.scalar != null) {
      final v = double.tryParse(p.scalar!.trim());
      if (v != null) numFreq[v] = (numFreq[v] ?? 0) + 1;
    }
  }

  // candidate byte positions per node: from a unique name-ref, a unique value-ref,
  // or (Num) the f64. Label which anchor produced it.
  final cands = <int, List<(int, String)>>{}; // dfs -> [(pos, why)]
  for (final (idx, p) in nodes) {
    final list = <(int, String)>[];
    final nr = uniqueRel(p.name);
    if (nr != null && nr > 8) {
      for (final pos in findRef(nr)) {
        list.add((pos, 'name@$nr'));
      }
    }
    if (p.className == 'Num' && p.scalar != null) {
      final v = double.tryParse(p.scalar!.trim());
      if (v != null && v != 0 && numFreq[v] == 1) {
        for (final pos in findF64(v)) {
          list.add((pos, 'f64=$v'));
        }
      }
    } else if (p.scalar != null && p.scalar!.isNotEmpty) {
      final vr = uniqueRel(p.scalar) ?? uniqueRel('"${p.scalar}"');
      if (vr != null && vr > 8) {
        for (final pos in findRef(vr)) {
          list.add((pos, 'val@$vr'));
        }
      }
    }
    list.sort((a, b) => a.$1.compareTo(b.$1));
    if (list.isNotEmpty) cands[idx] = list;
  }

  // greedy monotone assignment in DFS order
  var last = -1;
  final assigned = <(int, int, String, SeqProperty)>[]; // dfs, pos, why, node
  for (final (idx, p) in nodes) {
    final list = cands[idx];
    if (list == null) continue;
    (int, String)? pick;
    for (final c in list) {
      if (c.$1 > last) { pick = c; break; }
    }
    if (pick == null) continue;
    assigned.add((idx, pick.$1, pick.$2, p));
    last = pick.$1;
  }

  stdout.writeln('$which: ${nodes.length} nodes, ${cands.length} anchorable, '
      '${assigned.length} assigned monotonically. rr=$rr');
  var prev = -1;
  for (final (idx, pos, why, p) in assigned) {
    final d = prev < 0 ? 0 : pos - prev;
    stdout.writeln('  @${pos.toString().padLeft(6)} (+${d.toString().padLeft(4)})  '
        'dfs=${idx.toString().padLeft(3)}  ${p.className ?? '?'}/${p.name}  [$why]');
    prev = pos;
  }
}
