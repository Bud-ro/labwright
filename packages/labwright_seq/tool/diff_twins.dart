// Differential decode: find long common byte runs between two twins' inflated
// record regions. Standard type definitions (StepType, TEResult, ...) are shared
// boilerplate, so they appear as identical runs across files of the same TestStand
// version — isolating exactly the bytes that are decodable structure (vs
// file-specific content). Run: dart run tool/diff_twins.dart [A] [B] [minRun]
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

(Uint8List, int) _load(String which) {
  final raw = Uint8List.fromList(_find(which)!.readAsBytesSync());
  return (inflateBinaryBody(raw)!, analyzeBinaryBody(raw)!.recordRegionLength);
}

void main(List<String> args) {
  final aName = args.isEmpty ? 'OutputVoltage' : args[0];
  final bName = args.length > 1 ? args[1] : 'NIDmm';
  final minRun = args.length > 2 ? int.parse(args[2]) : 32;
  final (a, arr) = _load(aName);
  final (b, brr) = _load(bName);
  // pool names of A for annotating common runs
  final rel = <int, String>{
    for (final s in binaryStrings(a, minLength: 2))
      if (s.offset >= arr) s.offset - arr: s.text,
  };
  final av = ByteData.sublistView(a);

  // index 16-byte windows of B by a rolling key (only within B's record region)
  const k = 16;
  final idx = <int, List<int>>{};
  for (var i = 0; i + k <= brr; i++) {
    var h = 0;
    for (var j = 0; j < k; j++) {
      h = (h * 131 + b[i + j]) & 0x7fffffff;
    }
    (idx[h] ??= []).add(i);
  }

  // scan A's record region; on a window match, extend maximally; skip past run.
  final runs = <(int, int, int)>[]; // aPos, bPos, len
  for (var i = 0; i + k <= arr;) {
    var h = 0;
    for (var j = 0; j < k; j++) {
      h = (h * 131 + a[i + j]) & 0x7fffffff;
    }
    var best = 0, bestB = -1;
    for (final bp in idx[h] ?? const <int>[]) {
      // verify window, then extend
      var ok = true;
      for (var j = 0; j < k; j++) {
        if (a[i + j] != b[bp + j]) { ok = false; break; }
      }
      if (!ok) continue;
      var len = k;
      while (i + len < arr && bp + len < brr && a[i + len] == b[bp + len]) {
        len++;
      }
      if (len > best) { best = len; bestB = bp; }
    }
    if (best >= minRun) {
      runs.add((i, bestB, best));
      i += best;
    } else {
      i++;
    }
  }

  var common = 0;
  for (final r in runs) {
    common += r.$3;
  }
  stdout.writeln('$aName(rr=$arr) vs $bName(rr=$brr): '
      '${runs.length} common runs >=$minRun B, $common B total\n');
  for (final (ap, bp, len) in runs) {
    // resolve name-refs (u32 rel-offsets) inside the run for context
    final names = <String>{};
    for (var o = 0; o + 4 <= len; o++) {
      final v = av.getUint32(ap + o, Endian.little);
      final n = rel[v];
      if (n != null && v > 88 && n.length >= 3) names.add(n);
    }
    stdout.writeln('  A@${ap.toString().padLeft(5)} B@${bp.toString().padLeft(5)} '
        'len=${len.toString().padLeft(4)}'
        '${names.isEmpty ? '' : '   names: ${names.take(8).join(", ")}'}');
  }
}
