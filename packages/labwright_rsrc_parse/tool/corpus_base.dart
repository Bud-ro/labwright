import 'dart:convert';
import 'dart:io';

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
  final listing = await Process.run('tar', ['tzf', tarPath]);
  if (listing.exitCode != 0) {
    stderr.writeln('  tar list failed: ${listing.stderr}');
    return -1;
  }
  final members = (listing.stdout as String)
      .split('\n')
      .where((p) => p.isNotEmpty && keepExts.any((e) => p.toLowerCase().endsWith(e)))
      .toList();
  if (members.isEmpty) return 0;
  final proc = await Process.start('tar', [
    'xzf',
    tarPath,
    '-C',
    destPath,
    '--null',
    '--files-from=-',
    '--no-wildcards',
  ]);
  final errFuture = proc.stderr.transform(utf8.decoder).join();
  proc.stdin.add(utf8.encode(members.map((m) => '$m${String.fromCharCode(0)}').join()));
  await proc.stdin.close();
  final code = await proc.exitCode;
  final err = await errFuture;
  if (code != 0) {
    stderr.writeln('  tar extract failed ($code): ${err.trim()}');
    return -1;
  }
  return members.length;
}
