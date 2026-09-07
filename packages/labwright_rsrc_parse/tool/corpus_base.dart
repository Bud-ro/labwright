import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

Directory corpusBaseDir() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final rel in const [pkgRel, 'corpus']) {
      if (File('${dir.path}/$rel/sources.json').existsSync()) {
        return Directory('${dir.path}/$rel');
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus');
}

List<File> listCorpusVis(Directory root) {
  if (!root.existsSync()) return <File>[];
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Future<bool> ghTarball(String repo, String commit, String tarPath) async {
  final Process proc;
  try {
    proc = await Process.start('gh', ['api', 'repos/$repo/tarball/$commit']);
  } on ProcessException catch (e) {
    stderr.writeln('  gh not runnable: ${e.message} (is the GitHub CLI installed + authenticated?)');
    return false;
  }
  final sink = File(tarPath).openWrite();
  final errFuture = proc.stderr.transform(utf8.decoder).join();
  await proc.stdout.pipe(sink);
  final err = await errFuture;
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('  gh api failed ($code): ${err.trim()}');
    return false;
  }
  return true;
}

Future<int> extractSelected(String tarPath, String destPath, List<String> keepExts) async {
  final Archive archive;
  try {
    archive = TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(File(tarPath).readAsBytesSync()));
  } catch (e) {
    stderr.writeln('  tarball decode failed: $e');
    return -1;
  }
  var count = 0;
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name.toLowerCase();
    if (!keepExts.any(name.endsWith)) continue;
    final out = File('$destPath/${entry.name}');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(entry.content);
    count++;
  }
  return count;
}
