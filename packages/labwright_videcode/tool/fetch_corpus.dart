import 'dart:convert';
import 'dart:io';

/// Fetches the pinned diverse VI corpus cataloged in `corpus/sources.json`.
///
/// A Dart port of `corpus/fetch.sh`: the `.vi` files are NOT committed
/// (clean-room + licensing), so this pulls each source repo at its pinned commit
/// — making the corpus reproducible. Requires `gh` (authenticated) and `tar`.
///
/// Usage:
///   dart run tool/fetch_corpus.dart [destRoot]
///
/// `destRoot` defaults to `<repoRoot>/corpus/vi/` — a gitignored folder at the
/// repo root, kept there (not in /tmp) for visibility into what the corpus tests
/// + coverage tool consume (see corpus/README.md and test/corpus_dirs.dart). Each
/// repo extracts to `<destRoot>/<owner>_<name>/`; already-populated dirs are
/// skipped, so re-running only fetches what's missing.
Future<void> main(List<String> args) async {
  final sources = _findSourcesJson();
  if (sources == null) {
    stderr.writeln('error: could not locate corpus/sources.json (run from within the repo)');
    exitCode = 1;
    return;
  }
  // Repo root = the dir holding corpus/sources.json (i.e. <repoRoot>/corpus/sources.json).
  final repoRoot = sources.parent.parent.path;
  final dest = args.isNotEmpty ? args.first : '$repoRoot/corpus/vi';
  final list = (jsonDecode(sources.readAsStringSync())['sources'] as List).cast<Map<String, dynamic>>();

  Directory(dest).createSync(recursive: true);
  stdout.writeln('corpus dest: $dest  (${list.length} sources from ${sources.path})');

  var fetched = 0, skipped = 0, failed = 0, viTotal = 0;
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
    stdout.writeln('fetch $repo @ ${commit.substring(0, 12)}');

    final ok = await _ghTarball(repo, commit, tar);
    if (!ok) {
      failed++;
      if (File(tar).existsSync()) File(tar).deleteSync();
      continue;
    }
    final untar = await Process.run('tar', ['xzf', tar, '-C', out.path]);
    File(tar).deleteSync();
    if (untar.exitCode != 0) {
      stderr.writeln('  tar failed: ${untar.stderr}');
      failed++;
      continue;
    }
    fetched++;
    final n = out.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).length;
    viTotal += n;
    stdout.writeln('  ok ($n .vi)');
  }

  // Count the whole tree so re-runs (mostly skips) still report the real total.
  final grandTotal = Directory(dest).existsSync()
      ? Directory(dest).listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).length
      : 0;
  stdout.writeln('done: fetched=$fetched skipped=$skipped failed=$failed '
      '(this run +$viTotal .vi); corpus now holds $grandTotal .vi at $dest');
  if (failed > 0) exitCode = 1;
}

/// Streams `gh api repos/<repo>/tarball/<commit>` to [tarPath]. Returns true on
/// success. Drains stderr concurrently so a large error stream can't deadlock.
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
  await proc.stdout.pipe(sink); // pipe closes the sink when stdout hits EOF
  final err = await errFuture;
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('  gh api failed ($code): ${err.trim()}');
    return false;
  }
  return true;
}

/// Walks up from this script's directory to find the repo's `corpus/sources.json`.
File? _findSourcesJson() {
  var dir = File.fromUri(Platform.script).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}/corpus/sources.json');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Fallback: cwd-relative (when run from the repo root).
  final cwd = File('corpus/sources.json');
  return cwd.existsSync() ? cwd : null;
}
