// Rank the unmodeled `Data`-tree paths across the corpus, so XML/INI model
// completion work targets the biggest raw masses first. Aggregates
// `coverageGaps` over every XML (and optionally INI) `.seq` and prints the top
// paths by total node count. Run: dart run tool/gaps.dart [xml|ini|both] [topN]
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

String _root() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/packages/labwright_seq/corpus/seq-sources.json').existsSync()) {
      return '${d.path}/packages/labwright_seq/corpus/seq';
    }
    if (File('${d.path}/corpus/seq-sources.json').existsSync()) return '${d.path}/corpus/seq';
    d = d.parent;
  }
  return 'corpus/seq';
}

void main(List<String> args) {
  final which = args.isEmpty ? 'xml' : args[0];
  final topN = args.length > 1 ? int.parse(args[1]) : 40;
  // Pass `w` as a third arg to weight each gap path by its raw subtree size
  // (where the unmodeled mass really is) instead of by raw-root count.
  final weighted = args.length > 2 && args[2] == 'w';
  final dir = Directory(_root());
  final totals = <String, int>{};
  var files = 0;
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = f.readAsBytesSync();
    final fmt = detectSeqFormat(bytes);
    final isXml = fmt == SeqFormat.xml, isIni = fmt == SeqFormat.ini;
    if (!(which == 'both' ? (isXml || isIni) : which == 'xml' ? isXml : isIni)) {
      continue;
    }
    if (isIni && bytes.length > 300 * 1024) continue; // INI OOM cap
    try {
      final sf = parseSeqFile(bytes);
      files++;
      coverageGaps(sf, weightBySubtree: weighted).forEach((path, n) {
        totals.update(path, (v) => v + n, ifAbsent: () => n);
      });
    } catch (_) {}
  }
  final ranked = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final sum = totals.values.fold(0, (a, b) => a + b);
  stdout.writeln('$which: $files files · ${ranked.length} distinct unmodeled '
      'path shapes · $sum unmodeled nodes total\n');
  for (final e in ranked.take(topN)) {
    stdout.writeln('${e.value.toString().padLeft(7)}  ${e.key}');
  }
}
