import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import '../tool/corpus_base.dart';

final Directory corpusViDir = Directory('${corpusBaseDir().path}/vi');

List<File>? _allVisCache;

List<File> corpusVis() => _allVisCache ??= listCorpusVis(corpusViDir);

File corpusSnapshotFile() => File('${corpusBaseDir().path}/snapshot.json');

bool isNonRsrcFixture(String path) => path.replaceAll(r'\', '/').endsWith('/rust-proxy/test_data/test.vi');

int get _workers => (Platform.numberOfProcessors - 2).clamp(1, 16);

Future<List<R>> corpusParallel<R>(List<File> files, R Function(Uint8List bytes, String path) perFile) async {
  if (files.isEmpty) return <R>[];
  final paths = files.map((f) => f.path).toList();
  final n = _workers < paths.length ? _workers : paths.length;
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % n].add(paths[i]);
  }
  final results = await Future.wait(
    chunks.map((chunk) => Isolate.run(() => [for (final p in chunk) perFile(File(p).readAsBytesSync(), p)])),
  );
  return [for (final r in results) ...r];
}

Future<List<(String, bool?)>> decodeSnippetPngs(Directory dir) async {
  final pngs = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return corpusParallel(pngs, (bytes, path) {
    final vi = extractSnippetVi(bytes);
    if (vi == null) return (path, null);
    final positioned = buildViModel(vi).blockDiagrams.any((d) => d.objects.any((o) => o.absBounds != null));
    return (path, positioned);
  });
}
