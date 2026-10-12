import 'dart:convert';
import 'dart:io';

import 'corpus.dart';

/// Run: `dart run tool/fetch_corpus.dart`
///
/// Checks out every corpus repository named in `corpus/repos.json` at its pinned commit into
/// `corpus/<group>/<repository name>`, restricted to the listed `paths` when there are any.
Future<void> main() async {
  final root = repoRoot().path;
  final manifest = jsonDecode(File('$root/corpus/repos.json').readAsStringSync()) as Map<String, dynamic>;
  for (final MapEntry(key: group, value: repos) in manifest.entries) {
    for (final repo in (repos as List).cast<Map<String, dynamic>>()) {
      await _checkout(Directory('$root/corpus/$group/${_repoName(repo['repo'] as String)}'), repo);
    }
  }
}

String _repoName(String url) => url.split('/').last.replaceAll(RegExp(r'\.git$'), '');

Future<void> _checkout(Directory dest, Map<String, dynamic> repo) async {
  final url = repo['repo'] as String;
  final ref = repo['ref'] as String;
  final paths = ((repo['paths'] as List?) ?? const []).cast<String>();
  if (await _isCurrent(dest, ref, paths)) {
    stdout.writeln('${dest.path}: at ${ref.substring(0, 12)}');
    return;
  }
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  dest.createSync(recursive: true);
  stdout.writeln('${dest.path}: $url @ ${ref.substring(0, 12)}${paths.isEmpty ? '' : ', ${paths.length} paths'}');
  await _git(dest, ['init', '-q']);
  await _git(dest, ['remote', 'add', 'origin', url]);
  if (paths.isNotEmpty) await _git(dest, ['sparse-checkout', 'set', '--cone', ...paths]);
  await _git(dest, ['fetch', '-q', '--depth', '1', '--filter=blob:none', 'origin', ref]);
  await _git(dest, ['checkout', '-q', 'FETCH_HEAD']);
}

Future<bool> _isCurrent(Directory dest, String ref, List<String> paths) async {
  if (!Directory('${dest.path}/.git').existsSync()) return false;
  final head = await Process.run('git', ['-C', dest.path, 'rev-parse', 'HEAD']);
  if (head.exitCode != 0 || (head.stdout as String).trim() != ref) return false;
  final sparse = await Process.run('git', ['-C', dest.path, 'sparse-checkout', 'list']);
  final listed = sparse.exitCode == 0
      ? const LineSplitter().convert((sparse.stdout as String).trim())
      : const <String>[];
  return listed.toSet().containsAll(paths) && listed.length == paths.length;
}

Future<void> _git(Directory dir, List<String> args) async {
  final result = await Process.run('git', ['-C', dir.path, ...args]);
  if (result.exitCode != 0) throw StateError('git ${args.join(' ')} failed in ${dir.path}: ${result.stderr}');
}
