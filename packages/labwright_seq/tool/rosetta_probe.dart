// Decode aid for the binary `TOF1` record grammar: aligns a Rosetta binary
// `.seq` against its XML twin (the same sequence in both formats) so the
// PropertyObject record stream can be reverse-engineered against a known tree.
// Prints the XML ground-truth tree, the binary name table (string-region
// rel-offsets), a flat XML DFS, and every record word that resolves to a
// non-zero name offset with its header context. See NOTES.md ("Binary TOF1
// record grammar") for what this has established so far.
//
// Run: dart run tool/rosetta_probe.dart <name>    (NIScope | NIDmm | NIFgen)
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

String _dir() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    final r = Directory('${d.path}/packages/labwright_seq/corpus/seq/rosetta');
    if (r.existsSync()) return r.path;
    final r2 = Directory('${d.path}/corpus/seq/rosetta');
    if (r2.existsSync()) return r2.path;
    d = d.parent;
  }
  return 'corpus/seq/rosetta';
}

void printTree(SeqProperty p, {int depth = 0, int maxDepth = 6}) {
  if (depth > maxDepth) return;
  final indent = '  ' * depth;
  final cls = p.className == null ? '' : ' cls=${p.className}';
  final ty = p.typeName == null ? '' : ' ty=${p.typeName}';
  final sc = p.scalar == null ? '' : ' = ${_short(p.scalar!)}';
  final arr = p.array == null ? '' : ' [array ${p.array!.length}]';
  stdout.writeln('$indent${p.name}$cls$ty$arr$sc');
  for (final c in p.subProps) {
    printTree(c, depth: depth + 1, maxDepth: maxDepth);
  }
  for (final e in p.array ?? const <SeqProperty>[]) {
    printTree(e, depth: depth + 1, maxDepth: maxDepth);
  }
}

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 50 ? '${one.substring(0, 50)}…' : one;
}

void main(List<String> args) {
  final which = args.isEmpty ? 'NIScope' : args[0];
  final dir = _dir();
  // Two naming schemes coexist: structural twins use `_labview_BIN`/`_python_XML`
  // (LabVIEW vs Python toolchain); the OutputVoltage content-exact twin (one file
  // re-saved binary->XML in git history) uses the plain `_BIN`/`_XML` suffix.
  File pick(List<String> suffixes) =>
      File('$dir/$which${suffixes.firstWhere((s) => File('$dir/$which$s').existsSync(), orElse: () => suffixes.first)}');
  final binFile = pick(['_BIN.seq', '_labview_BIN.seq']);
  final xmlFile = pick(['_XML.seq', '_python_XML.seq']);
  if (!binFile.existsSync() || !xmlFile.existsSync()) {
    stderr.writeln('missing pair for $which in $dir');
    exit(1);
  }
  final bin = Uint8List.fromList(binFile.readAsBytesSync());
  final xml = Uint8List.fromList(xmlFile.readAsBytesSync());

  stdout.writeln('========== XML twin tree ($which) ==========');
  final sf = parseSeqFile(xml);
  printTree(sf.data, maxDepth: 5);

  stdout.writeln('\n========== BINARY twin recon ($which) ==========');
  final a = analyzeBinary(bin)!;
  stdout.writeln('inflated=${a.inflatedSize}  layout=${a.layout}');
  stdout.writeln('--- name table (rel-offset: text) ---');
  final rr = a.layout!.recordRegionLength;
  for (final e in a.nameTable) {
    stdout.writeln('  ${(e.offset - rr).toString().padLeft(6)}: ${e.text}');
  }
  stdout.writeln('--- XML DFS flat (name | cls | ty | scalar) ---');
  final flat = <String>[];
  void dfs(SeqProperty p) {
    flat.add('${p.name} | ${p.className ?? ''} | ${p.typeName ?? ''} | '
        '${p.scalar == null ? '' : _short(p.scalar!)}');
    for (final c in p.subProps) {
      dfs(c);
    }
    for (final e in p.array ?? const <SeqProperty>[]) {
      dfs(e);
    }
  }

  dfs(sf.data);
  for (var i = 0; i < flat.length; i++) {
    stdout.writeln('  ${i.toString().padLeft(3)}: ${flat[i]}');
  }

  stdout.writeln('--- record words that hit a NON-ZERO name offset '
      '(idx: [w-1] name [w+1 w+2 w+3]) ---');
  final relToName = <int, String>{
    for (final s in binaryStrings(Uint8List.fromList(inflateBinaryBody(bin)!), minLength: 2))
      if (s.offset >= rr) s.offset - rr: s.text,
  };
  final words = binaryRecordWords(bin);
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (w == 0) continue;
    final nm = relToName[w];
    if (nm == null) continue;
    final pre = i > 0 ? words[i - 1] : -1;
    final p1 = i + 1 < words.length ? words[i + 1] : -1;
    final p2 = i + 2 < words.length ? words[i + 2] : -1;
    final p3 = i + 3 < words.length ? words[i + 3] : -1;
    stdout.writeln('  ${i.toString().padLeft(4)}: [pre=$pre] "$nm" '
        '[+1=$p1 +2=$p2 +3=$p3]');
  }
}

