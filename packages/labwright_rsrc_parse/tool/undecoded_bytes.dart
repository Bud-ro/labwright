import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Per-tag totals of DECODER-LESS block bytes across the whole corpus — the
/// worklist for driving the coverage tool's decBytes% axis to 100%. For each
/// section (decompressed), attributes its byte count to its tag; prints tags
/// with no registered decoder, largest first, with their catalog note.
///
/// Run: `dart run tool/undecoded_bytes.dart [corpusDir]`
String _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/$pkgRel/sources.json').existsSync()) return '${dir.path}/$pkgRel';
    if (File('${dir.path}/corpus/sources.json').existsSync()) return '${dir.path}/corpus';
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return 'corpus';
}

void main(List<String> args) {
  final dir = Directory(args.isNotEmpty ? args[0] : '${_corpusBase()}/vi');
  if (!dir.existsSync()) {
    stderr.writeln('corpus dir not found: ${dir.path}');
    exit(1);
  }
  final vis = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final bytesByTag = <String, int>{};
  final sectionsByTag = <String, int>{};
  var totalBytes = 0;
  for (final file in vis) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        final n = decoded.bytes.length;
        totalBytes += n;
        bytesByTag.update(decoded.tag, (v) => v + n, ifAbsent: () => n);
        sectionsByTag.update(decoded.tag, (v) => v + 1, ifAbsent: () => 1);
      }
    } catch (_) {}
  }

  final undecoded = [
    for (final entry in bytesByTag.entries)
      if (blockInfo(entry.key).decoder == null) entry,
  ]..sort((a, b) => b.value.compareTo(a.value));

  final undecodedTotal = undecoded.fold<int>(0, (sum, e) => sum + e.value);
  stdout.writeln('corpus: ${vis.length} VIs · $totalBytes decompressed block bytes · '
      '$undecodedTotal (${(100 * undecodedTotal / totalBytes).toStringAsFixed(1)}%) in decoder-less tags\n');
  stdout.writeln('tag    sections       bytes   share  note');
  for (final entry in undecoded.take(40)) {
    final info = blockInfo(entry.key);
    final note = info.note.split('.').first;
    stdout.writeln('${entry.key.padRight(6)} ${sectionsByTag[entry.key].toString().padLeft(8)} '
        '${entry.value.toString().padLeft(11)} '
        '${(100 * entry.value / totalBytes).toStringAsFixed(2).padLeft(6)}%  '
        '${note.length > 90 ? note.substring(0, 90) : note}');
  }
}
