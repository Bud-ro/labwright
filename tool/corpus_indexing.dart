import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The directories of a corpus repository that each carry an `index.json`: every vendored
/// source under `sources/`, or the repository itself when it has no `sources/` directory.
List<Directory> corpusIndexRoots(Directory corpus) {
  final sources = Directory('${corpus.path}/sources');
  if (!sources.existsSync()) return [corpus];
  return sources.listSync(followLinks: false).whereType<Directory>().where(_hasFiles).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

bool _hasFiles(Directory dir) => dir.listSync(followLinks: false).isNotEmpty;

/// The files under [root] an index records, by path relative to [root] with `/` separators,
/// sorted; a PNG counts until the indexer finds it carries no VI. A nested repository (a
/// directory holding a `.git` entry) is not part of the corpus, as git itself would not add it.
List<String> corpusIndexCandidates(Directory root) {
  final prefix = root.path.length + 1;
  final out = <String>[];
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    if (dir.path != root.path && _isRepository(dir)) continue;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        if (entity.uri.pathSegments.where((s) => s.isNotEmpty).last != '.git') pending.add(entity);
      } else if (entity is File) {
        final relative = entity.path.substring(prefix).replaceAll(r'\', '/');
        if (CorpusFileType.ofPath(relative) != null) out.add(relative);
      }
    }
  }
  return out..sort();
}

bool _isRepository(Directory dir) => FileSystemEntity.typeSync('${dir.path}/.git') != FileSystemEntityType.notFound;

/// The index of the files under [root], built on [workers] isolates.
Future<CorpusIndex> buildCorpusIndex(Directory root, {int? workers}) async {
  final paths = corpusIndexCandidates(root);
  final n = (workers ?? defaultIndexWorkers).clamp(1, paths.isEmpty ? 1 : paths.length);
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % n].add(paths[i]);
  }
  final parts = await Future.wait([
    for (final chunk in chunks)
      if (chunk.isNotEmpty) Isolate.run(() => _indexFiles(root.path, chunk)),
  ]);
  return CorpusIndex([for (final part in parts) ...part]);
}

List<CorpusIndexEntry> _indexFiles(String root, List<String> paths) => [
  for (final path in paths)
    if (indexCorpusFile(path, File('$root/$path').readAsBytesSync()) case final entry?) entry,
];

int get defaultIndexWorkers => (Platform.numberOfProcessors - 1).clamp(1, 16);

/// The outcome of bringing one index file up to date.
enum IndexFileState { unchanged, written, stale, missing }

/// Rebuilds the `index.json` of every index root of [corpus], or of the [roots] given, and
/// writes those that differ unless [check] is set, in which case nothing is written; returns
/// each index file with what was found.
Future<Map<File, IndexFileState>> updateCorpusIndexes(
  Directory corpus, {
  List<Directory>? roots,
  bool check = false,
  int? workers,
  void Function(File file, IndexFileState state)? onDone,
}) async {
  final out = <File, IndexFileState>{};
  for (final root in roots ?? corpusIndexRoots(corpus)) {
    final file = File('${root.path}/${CorpusIndex.fileName}');
    final fresh = (await buildCorpusIndex(root, workers: workers)).encode();
    final IndexFileState state;
    if (!file.existsSync()) {
      state = check ? IndexFileState.missing : IndexFileState.written;
    } else if (file.readAsStringSync() == fresh) {
      state = IndexFileState.unchanged;
    } else {
      state = check ? IndexFileState.stale : IndexFileState.written;
    }
    if (state == IndexFileState.written) file.writeAsStringSync(fresh);
    out[file] = state;
    onDone?.call(file, state);
  }
  return out;
}
