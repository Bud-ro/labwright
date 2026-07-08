import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../tool/corpus_base.dart';

/// The pinned VI corpus directory; corpus tests skip when it is absent.
final Directory corpusViDir = Directory('${corpusBaseDir().path}/vi');

List<File>? _allVisCache;

/// Every `.vi` in the corpus (recursive, symlinks excluded, path-sorted), cached per run.
/// Corpus tests run over ALL of these — no sampling; per-VI work is parallelized via [corpusParallel].
List<File> corpusVis() => _allVisCache ??= listCorpusVis(corpusViDir);

/// The coverage baseline written by `tool/coverage.dart`.
File corpusBaselineFile() => File('${corpusBaseDir().path}/baseline.json');

/// The per-VI feature snapshot written by `tool/snapshot.dart`.
File corpusSnapshotFile() => File('${corpusBaseDir().path}/snapshot.json');

/// A corpus entry that is deliberately NOT a valid RSRC file (an upstream few-byte test fixture).
/// Totality checks exclude it; any OTHER unparseable file still fails loudly.
bool isNonRsrcFixture(String path) => path.replaceAll(r'\', '/').endsWith('/rust-proxy/test_data/test.vi');

/// Worker count: one isolate per core, less two so the machine stays responsive, capped at 16.
int get _workers => (Platform.numberOfProcessors - 2).clamp(1, 16);

/// Runs [perFile] over every file across a bounded pool of worker isolates and returns the results
/// (order not preserved). [perFile] MUST be a top-level/static function and its return type sendable.
/// Files are split round-robin so giant VIs spread across workers; each worker holds only its current
/// VI's working set, keeping peak memory bounded.
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
