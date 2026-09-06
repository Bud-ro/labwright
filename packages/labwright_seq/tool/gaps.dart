import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

String _root() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final base in ['${d.path}/packages/labwright_seq/corpus', '${d.path}/corpus']) {
      if (File('$base/seq-sources.json').existsSync()) return '$base/seq';
    }
    d = d.parent;
  }
  return 'corpus/seq';
}

void main(List<String> args) {
  final which = args.isEmpty ? 'xml' : args[0];
  final topN = args.length > 1 ? int.parse(args[1]) : 40;
  final weighted = args.length > 2 && args[2] == 'w';
  final dir = Directory(_root());
  final totals = <String, int>{};
  var files = 0;
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = f.readAsBytesSync();
    final fmt = detectSeqFormat(bytes);
    final ok = switch (which) {
      'both' => fmt == SeqFormat.xml || fmt == SeqFormat.ini,
      'xml' => fmt == SeqFormat.xml,
      _ => fmt == SeqFormat.ini,
    };
    if (!ok) continue;
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
  stdout.writeln(
    '$which: $files files · ${ranked.length} distinct unmodeled '
    'path shapes · $sum unmodeled nodes total\n',
  );
  for (final e in ranked.take(topN)) {
    stdout.writeln('${e.value.toString().padLeft(7)}  ${e.key}');
  }
}
