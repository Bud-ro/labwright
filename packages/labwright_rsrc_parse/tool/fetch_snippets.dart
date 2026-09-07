import 'dart:convert';
import 'dart:io';

import 'corpus_base.dart';

/// Usage:
///   dart run tool/fetch_snippets.dart [destRoot]
Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final sources = File('${corpusBaseDir().path}/snippets/sources.json');
  if (!sources.existsSync()) {
    stderr.writeln('error: could not locate corpus/snippets/sources.json (run from within the repo)');
    exitCode = 1;
    return;
  }
  final dest = positional.isNotEmpty ? positional.first : '${sources.parent.path}/bulk';
  final list = (jsonDecode(sources.readAsStringSync())['sources'] as List).cast<Map<String, dynamic>>();
  Directory(dest).createSync(recursive: true);
  stdout.writeln('snippet dest: $dest  (${list.length} sources from ${sources.path})');

  var fetched = 0, skipped = 0, failed = 0;
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
    final ok = await _download('https://codeload.github.com/$repo/tar.gz/$commit', File(tar));
    if (!ok) {
      failed++;
      if (File(tar).existsSync()) File(tar).deleteSync();
      continue;
    }
    final extracted = await extractSelected(tar, out.path, const [
      '.png',
      'manifest.json',
      'licenses.md',
      'interesting.txt',
    ]);
    File(tar).deleteSync();
    final pngs = extracted < 0
        ? -1
        : out.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).length;
    if (pngs != s['files']) {
      stderr.writeln('  expected ${s['files']} snippets, got $pngs');
      failed++;
      continue;
    }
    stdout.writeln('  ok ($pngs snippets)');
    fetched++;
  }
  stdout.writeln('done: fetched=$fetched skipped=$skipped failed=$failed');
  if (failed > 0) exitCode = 1;
}

Future<bool> _download(String url, File to) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('  HTTP ${response.statusCode} for $url');
      return false;
    }
    await response.pipe(to.openWrite());
    return true;
  } catch (e) {
    stderr.writeln('  download failed: $e');
    return false;
  } finally {
    client.close();
  }
}
