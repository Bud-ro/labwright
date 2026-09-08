import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

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
  throw StateError('no corpus/sources.json at or above ${Directory.current.path}');
}

List<File> listCorpusVis(Directory root) {
  if (!root.existsSync()) return <File>[];
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
}

File findCatalog(String fileName) {
  var dir = File.fromUri(Platform.script).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}/corpus/$fileName');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('no corpus/$fileName at or above ${Platform.script}');
}

int countFiles(Directory root, String extension) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.toLowerCase().endsWith(extension))
    .length;

class FetchTally {
  int fetched = 0;
  int skipped = 0;
  int failed = 0;
  int files = 0;

  @override
  String toString() => 'fetched=$fetched skipped=$skipped failed=$failed (this run +$files files)';
}

Future<FetchTally> fetchSources(List<Map<String, dynamic>> sources, String dest, List<String> keepExts) async {
  final tally = FetchTally();
  for (final source in sources) {
    final repo = source['repo'] as String;
    final commit = source['commit'] as String;
    final out = Directory('$dest/${repo.replaceAll('/', '_')}');
    if (out.existsSync() && out.listSync().isNotEmpty) {
      stdout.writeln('skip  $repo (already present)');
      tally.skipped++;
      continue;
    }
    out.createSync(recursive: true);
    final tar = '${out.path}.tar.gz';
    stdout.writeln('fetch $repo @ ${commit.substring(0, 12)}');
    if (!await ghTarball(repo, commit, tar)) {
      tally.failed++;
      if (File(tar).existsSync()) File(tar).deleteSync();
      continue;
    }
    final keep = (source['keep'] as List?)?.cast<String>() ?? keepExts;
    final extracted = await extractSelected(tar, out.path, keep);
    File(tar).deleteSync();
    if (extracted < 0) {
      tally.failed++;
      continue;
    }
    tally.fetched++;
    tally.files += extracted;
    stdout.writeln('  ok ($extracted files)');
  }
  return tally;
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

Future<bool> fetchRawFile(String repo, String commit, String path, String sha256Hex, File to) async {
  final client = HttpClient();
  try {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    final request = await client.getUrl(Uri.parse('https://raw.githubusercontent.com/$repo/$commit/$encoded'));
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('  HTTP ${response.statusCode} for $repo/$commit/$path');
      return false;
    }
    final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    final digest = sha256.convert(bytes).toString();
    if (digest != sha256Hex) {
      stderr.writeln('  sha256 mismatch for $path: got $digest');
      return false;
    }
    to.parent.createSync(recursive: true);
    to.writeAsBytesSync(bytes);
    return true;
  } catch (e) {
    stderr.writeln('  download failed: $e');
    return false;
  } finally {
    client.close();
  }
}

bool fileMatches(File file, String sha256Hex) =>
    file.existsSync() && sha256.convert(file.readAsBytesSync()).toString() == sha256Hex;
