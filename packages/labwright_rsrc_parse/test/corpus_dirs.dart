import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Resolves this package's corpus dir (`<pkg>/corpus/`), which holds the committed
/// JSON indices and the gitignored `vi/` checkout from `tool/fetch_corpus.dart`.
/// Tests run from either the repo root or the package dir (see the CWD probe), so
/// walk up from CWD checking both the package-relative location (CWD at/above the
/// repo root) and the package-local one (CWD == package root). Falls back to a
/// cwd-relative path.
Directory _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/$pkgRel/sources.json').existsSync()) {
      return Directory('${dir.path}/$pkgRel');
    }
    if (File('${dir.path}/corpus/sources.json').existsSync()) {
      return Directory('${dir.path}/corpus');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('corpus');
}

/// The whole VI corpus directory (every pinned source). Empty/absent until
/// fetched — corpus tests skip when it does not exist.
final Directory corpusViDir = Directory('${_corpusBase().path}/vi');

List<File>? _allVisCache;

/// Every `.vi` in the corpus, sorted by path (deterministic), cached per run. The
/// corpus tests run over ALL of these — there is no sampling tier; the heavy
/// per-VI work is parallelized across isolates instead (see [corpusParallel]).
List<File> corpusVis() {
  if (_allVisCache != null) return _allVisCache!;
  final d = corpusViDir;
  final list = d.existsSync()
      ? (d
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.vi'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  return _allVisCache = list;
}

/// The coverage baseline written by `tool/coverage.dart`, resolved next to the
/// package-local corpus (`<pkg>/corpus/baseline.json`).
File corpusBaselineFile() => File('${_corpusBase().path}/baseline.json');

/// The per-VI feature snapshot written by `tool/snapshot.dart`, resolved next to
/// the package-local corpus (`<pkg>/corpus/snapshot.json`).
File corpusSnapshotFile() => File('${_corpusBase().path}/snapshot.json');

/// A corpus entry that is deliberately NOT a valid RSRC/VI file — an upstream test
/// fixture (G-CLI's `rust-proxy/test_data/test.vi` is a few bytes, "too small to be
/// an RSRC file"). `parseVi`/`decodeSections` legitimately reject it (the coverage
/// tool counts it in the sub-100% parseOk), so the totality checks exclude it; any
/// OTHER unparseable file is a real regression and still fails loudly.
bool isNonRsrcFixture(String path) =>
    path.replaceAll(r'\', '/').endsWith('/rust-proxy/test_data/test.vi');

/// Worker count for [corpusParallel]: one isolate per core, less a couple so the
/// machine stays responsive, capped at 16.
int get _workers {
  final n = Platform.numberOfProcessors - 2;
  return n < 1 ? 1 : (n > 16 ? 16 : n);
}

/// Runs [perFile] over every file in [files] across a pool of isolates and returns
/// the results (order not preserved — each result should carry its own identity).
///
/// This is how the corpus tests stay fast while still covering the WHOLE corpus:
/// the expensive per-VI work (`buildViModel`, IR/JSON encode, scaffold) runs in
/// parallel rather than sampling the corpus down. [perFile] MUST be a top-level (or
/// static) function — it is sent to the worker isolates — and its return type [R]
/// must be sendable (primitives, `List`/`Map`/`Set` of sendables, or a class whose
/// fields are all sendable). Files are split round-robin so the few giant VIs are
/// spread across workers rather than clustered in one. Peak memory is bounded:
/// Dart isolates share one OS process and each holds only its current VI's working
/// set.
Future<List<R>> corpusParallel<R>(
  List<File> files,
  R Function(Uint8List bytes, String path) perFile,
) async {
  if (files.isEmpty) return <R>[];
  final paths = files.map((f) => f.path).toList();
  final n = _workers < paths.length ? _workers : paths.length;
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % n].add(paths[i]);
  }
  final results = await Future.wait(
    chunks.map(
      (chunk) => Isolate.run(() => [
        for (final p in chunk) perFile(File(p).readAsBytesSync(), p),
      ]),
    ),
  );
  return [for (final r in results) ...r];
}
