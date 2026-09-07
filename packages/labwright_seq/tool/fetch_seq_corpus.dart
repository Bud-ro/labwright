import 'dart:convert';
import 'dart:io';

import '../../labwright_rsrc_parse/tool/corpus_base.dart';

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

    if (!await ghTarball(repo, commit, tar)) {
      failed++;
      if (File(tar).existsSync()) File(tar).deleteSync();
      continue;
    }
    final extracted = await extractSelected(tar, out.path, _extensions);
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
