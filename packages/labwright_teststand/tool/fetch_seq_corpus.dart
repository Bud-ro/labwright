import 'dart:convert';
import 'dart:io';

/// Fetches the pinned TestStand corpus cataloged in `corpus/seq-sources.json`.
///
/// Sibling of the VI corpus fetcher (`labwright_vi_parse/tool/fetch_corpus.dart`)
/// — same approach: the `.seq`/config files are NOT committed (clean-room +
/// licensing), so this pulls each source repo at its pinned commit, making the
/// corpus reproducible. Requires `gh` (authenticated) and `tar`.
///
/// Usage:
///   dart run tool/fetch_seq_corpus.dart [destRoot]
///
/// `destRoot` defaults to the gitignored `<repoRoot>/corpus/seq/`. Each repo
/// extracts to `<destRoot>/<owner>_<name>/`; already-populated dirs are skipped,
/// so re-running only fetches what's missing.
const _extensions = ['.seq', '.ini', '.cfg', '.tsw', '.tpj'];

Future<void> main(List<String> args) async {
  final sources = _findCatalog();
  if (sources == null) {
    stderr.writeln('error: could not locate corpus/seq-sources.json (run from within the repo)');
    exitCode = 1;
    return;
  }
  final repoRoot = sources.parent.parent.path;
  final dest = args.isNotEmpty ? args.first : '$repoRoot/corpus/seq';
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
    final untar = await Process.run('tar', ['xzf', tar, '-C', out.path]);
    File(tar).deleteSync();
    if (untar.exitCode != 0) {
      stderr.writeln('  tar failed: ${untar.stderr}');
      failed++;
      continue;
    }
    fetched++;
    final n = _countCorpusFiles(out);
    seqTotal += n;
    stdout.writeln('  ok ($n corpus files; ${_countSeq(out)} .seq)');
  }

  final grand = Directory(dest).existsSync() ? _countSeq(Directory(dest)) : 0;
  stdout.writeln('done: fetched=$fetched skipped=$skipped failed=$failed '
      '(this run +$seqTotal corpus files); corpus now holds $grand .seq at $dest');
  if (failed > 0) exitCode = 1;
}

int _countCorpusFiles(Directory d) => d
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => _extensions.any((e) => f.path.toLowerCase().endsWith(e)))
    .length;

int _countSeq(Directory d) => d
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.toLowerCase().endsWith('.seq'))
    .length;

/// Streams `gh api repos/<repo>/tarball/<commit>` to [tarPath]. Drains stderr
/// concurrently so a large error stream can't deadlock.
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

/// Walks up from this script to find `corpus/seq-sources.json`.
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
