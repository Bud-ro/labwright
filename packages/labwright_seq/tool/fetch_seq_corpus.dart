import 'dart:convert';
import 'dart:io';

const _extensions = ['.seq', '.ini', '.cfg', '.tsw', '.tpj'];

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final sources = _findCatalog();
  if (sources == null) {
    stderr.writeln('error: could not locate corpus/seq-sources.json (run from within the repo)');
    exitCode = 1;
    return;
  }
  final pkgRoot = sources.parent.parent.path;
  final dest = positional.isNotEmpty ? positional.first : '$pkgRoot/corpus/seq';

  final list = (jsonDecode(sources.readAsStringSync())['sources'] as List).cast<Map<String, dynamic>>();

  Directory(dest).createSync(recursive: true);
  stdout.writeln('seq corpus dest: $dest  (${list.length} sources from ${sources.path})');

  var fetched = 0, skipped = 0, failed = 0, seqTotal = 0;
  for (final s in list) {
    final repo = s['repo'] as String;
    final commit = s['commit'] as String;
    final out = Directory('$dest/${repo.replaceAll('/', '_')}');
    if (out.existsSync() && out.listSync().isNotEmpty) {
      stdout.writeln('skip  $repo (already present)');
      skipped++;
      continue;
    }
    out.createSync(recursive: true);
    final tar = '${out.path}.tar.gz';
    stdout.writeln('fetch $repo @ ${commit.substring(0, 12)}  [${s['encoding'] ?? '?'}]');

    if (!await _ghTarball(repo, commit, tar)) {
      failed++;
      if (File(tar).existsSync()) File(tar).deleteSync();
      continue;
    }
    final extracted = await _extractSelected(tar, out.path, _extensions);
    File(tar).deleteSync();
    if (extracted < 0) {
      failed++;
      continue;
    }
    fetched++;
    seqTotal += extracted;
    stdout.writeln('  ok ($extracted corpus files; ${_countSeq(out)} .seq)');
  }

  final grand = _countSeq(Directory(dest));
  stdout.writeln(
    'done: fetched=$fetched skipped=$skipped failed=$failed '
    '(this run +$seqTotal corpus files); corpus now holds $grand .seq at $dest',
  );
  if (failed > 0) exitCode = 1;
}

int _countSeq(Directory d) =>
    d.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.seq')).length;

Future<bool> _ghTarball(String repo, String commit, String tarPath) async {
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

Future<int> _extractSelected(String tarPath, String destPath, List<String> keepExts) async {
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
  proc.stdin.add(utf8.encode('${members.join('\x00')}\x00'));
  await proc.stdin.close();
  final code = await proc.exitCode;
  final err = await errFuture;
  if (code != 0) {
    stderr.writeln('  tar extract failed ($code): ${err.trim()}');
    return -1;
  }
  return members.length;
}

File? _findCatalog() {
  var dir = File.fromUri(Platform.script).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}/corpus/seq-sources.json');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final cwd = File('corpus/seq-sources.json');
  return cwd.existsSync() ? cwd : null;
}
