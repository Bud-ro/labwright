import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'corpus.dart';

Future<void> main() async {
  final root = repoRoot().path;
  final manifest = jsonDecode(File('$root/corpus/sources.json').readAsStringSync()) as Map<String, dynamic>;
  var failed = 0;
  for (final MapEntry(key: name, value: group) in manifest.cast<String, Map<String, dynamic>>().entries) {
    final dest = Directory('$root/corpus/$name')..createSync(recursive: true);
    final keep = (group['keep'] as List).cast<String>();
    final sources = (group['sources'] as List).cast<Map<String, dynamic>>();
    final files = ((group['files'] as List?) ?? const []).cast<Map<String, dynamic>>();
    stdout.writeln('corpus/$name: ${sources.length} sources, ${files.length} pinned files');
    for (final source in sources) {
      if (!await _fetchSource(source, dest, keep)) failed++;
    }
    for (final pinned in files) {
      if (!await _fetchPinnedFile(pinned, dest)) failed++;
    }
    for (final extension in keep) {
      stdout.writeln('  ${corpusFiles(dest, extension).length} $extension');
    }
  }
  if (failed > 0) exitCode = 1;
}

Future<bool> _fetchSource(Map<String, dynamic> source, Directory dest, List<String> keep) async {
  final repo = source['repo'] as String;
  final commit = source['commit'] as String;
  final out = Directory('${dest.path}/${repo.replaceAll('/', '_')}');
  if (out.existsSync() && out.listSync().isNotEmpty) return true;
  out.createSync(recursive: true);
  final tar = File('${out.path}.tar.gz');
  stdout.writeln('fetch $repo @ ${commit.substring(0, 12)}');
  try {
    if (!await _ghTarball(repo, commit, tar)) return false;
    final extracted = _extractSelected(tar, out, (source['keep'] as List?)?.cast<String>() ?? keep);
    stdout.writeln('  ok ($extracted files)');
    return true;
  } finally {
    if (tar.existsSync()) tar.deleteSync();
  }
}

Future<bool> _ghTarball(String repo, String commit, File tar) async {
  final process = await Process.start('gh', ['api', 'repos/$repo/tarball/$commit']);
  final errors = process.stderr.transform(utf8.decoder).join();
  await process.stdout.pipe(tar.openWrite());
  final code = await process.exitCode;
  if (code != 0) stderr.writeln('  gh api failed ($code): ${(await errors).trim()}');
  return code == 0;
}

int _extractSelected(File tar, Directory dest, List<String> keep) {
  final archive = TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(tar.readAsBytesSync()));
  var count = 0;
  for (final entry in archive) {
    if (!entry.isFile || !keep.any(entry.name.toLowerCase().endsWith)) continue;
    File('${dest.path}/${entry.name}')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(entry.content);
    count++;
  }
  return count;
}

Future<bool> _fetchPinnedFile(Map<String, dynamic> pinned, Directory dest) async {
  final file = File('${dest.path}/${pinned['to']}');
  final sha256Hex = pinned['sha256'] as String;
  if (file.existsSync() && sha256.convert(file.readAsBytesSync()).toString() == sha256Hex) return true;
  final repo = pinned['repo'] as String;
  final commit = pinned['commit'] as String;
  final path = pinned['path'] as String;
  stdout.writeln('fetch ${pinned['to']} from $repo @ ${commit.substring(0, 12)}');
  final client = HttpClient();
  try {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    final response = await (await client.getUrl(
      Uri.parse('https://raw.githubusercontent.com/$repo/$commit/$encoded'),
    )).close();
    if (response.statusCode != 200) {
      stderr.writeln('  HTTP ${response.statusCode} for $repo/$commit/$path');
      return false;
    }
    final bytes = await response.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
    final digest = sha256.convert(bytes).toString();
    if (digest != sha256Hex) {
      stderr.writeln('  sha256 mismatch for $path: got $digest');
      return false;
    }
    file
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return true;
  } finally {
    client.close();
  }
}
