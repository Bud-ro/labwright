import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

String _defaultCorpusRoot() {
  const pkgRel = 'packages/labwright_seq/corpus';
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/$pkgRel/seq-sources.json').existsSync()) return '${d.path}/$pkgRel/seq';
    if (File('${d.path}/corpus/seq-sources.json').existsSync()) return '${d.path}/corpus/seq';
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return 'corpus/seq';
}

void main(List<String> args) {
  var root = _defaultCorpusRoot();
  var gaps = 0;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--gaps') {
      gaps = int.parse(args[++i]);
    } else {
      root = args[i];
    }
  }
  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    stderr.writeln('corpus not found: $root (run tool/fetch_seq_corpus.dart)');
    exit(1);
  }

  String pct(num a, num b) => b == 0 ? '  0.0' : (100 * a / b).toStringAsFixed(1).padLeft(5);

  var total = const BinaryByteCoverage(bodyBytes: 0, poolBytes: 0, recordSemanticBytes: 0, recordStructuralBytes: 0);
  var files = 0, unframed = 0;
  File? worstFile;
  var worstGap = -1;

  final bySource = <String, List<File>>{};
  for (final src in rootDir.listSync().whereType<Directory>()) {
    final name = src.path.split('/').last;
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.seq')) (bySource[name] ??= []).add(f);
    }
  }

  stdout.writeln(
    'source                              bin      body     rec-sem% rec-str% rec-und%  body-acc%',
  );
  for (final src in bySource.keys.toList()..sort()) {
    var srcCov = const BinaryByteCoverage(bodyBytes: 0, poolBytes: 0, recordSemanticBytes: 0, recordStructuralBytes: 0);
    var srcFiles = 0;
    for (final f in bySource[src]!..sort((a, b) => a.path.compareTo(b.path))) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final cov = binaryByteCoverage(bytes);
      if (cov == null) {
        unframed++;
        continue;
      }
      srcFiles++;
      srcCov = srcCov + cov;
      if (cov.recordUndecodedBytes > worstGap) {
        worstGap = cov.recordUndecodedBytes;
        worstFile = f;
      }
    }
    if (srcFiles == 0) continue;
    files += srcFiles;
    total = total + srcCov;
    stdout.writeln(
      '${src.padRight(34).substring(0, 34)} ${srcFiles.toString().padLeft(4)} '
      '${srcCov.bodyBytes.toString().padLeft(9)} '
      '   ${pct(srcCov.recordSemanticBytes, srcCov.recordRegionBytes)}'
      '    ${pct(srcCov.recordStructuralBytes, srcCov.recordRegionBytes)}'
      '    ${pct(srcCov.recordUndecodedBytes, srcCov.recordRegionBytes)}'
      '      ${pct(srcCov.bodyBytes - srcCov.recordUndecodedBytes, srcCov.bodyBytes)}',
    );
  }
  stdout.writeln('-' * 100);
  stdout.writeln(
    'TOTAL $files binary .seq ($unframed unframed) · body ${total.bodyBytes} B '
    '(pool ${total.poolBytes} B = ${pct(total.poolBytes, total.bodyBytes).trim()}%, '
    'record region ${total.recordRegionBytes} B)',
  );
  stdout.writeln(
    'record region: semantic ${total.recordSemanticBytes} B (${pct(total.recordSemanticBytes, total.recordRegionBytes).trim()}%) · '
    'structural ${total.recordStructuralBytes} B (${pct(total.recordStructuralBytes, total.recordRegionBytes).trim()}%) · '
    'undecoded ${total.recordUndecodedBytes} B (${pct(total.recordUndecodedBytes, total.recordRegionBytes).trim()}%)',
  );
  stdout.writeln(
    'whole body:    semantic ${pct(total.recordSemanticBytes + total.poolBytes, total.bodyBytes).trim()}% · '
    'accounted ${pct(total.bodyBytes - total.recordUndecodedBytes, total.bodyBytes).trim()}%',
  );

  if (gaps > 0 && worstFile != null) {
    stdout.writeln('\nlargest-gap file: ${worstFile.path} ($worstGap undecoded B)');
    final spans = binaryUndecodedSpans(worstFile.readAsBytesSync(), max: gaps);
    for (final (start, end) in spans) {
      stdout.writeln('  [$start, $end) ${end - start} B');
    }
  }
}
