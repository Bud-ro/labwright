import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import '../../../tool/corpus.dart';
import '../tool/corpus_vis.dart';

export '../../../tool/corpus.dart';
export '../tool/corpus_vis.dart';

final Directory corpusViDir = corpusVi;

/// One corpus VI as the workers hold it across tests: the VI bytes (a snippet's embedded VI
/// when the file is a PNG, whose own bytes are [png]), the sections read and inflated once, the
/// model built once, and [error] when a stage threw, with that stage and the ones after it null.
class CorpusVi {
  CorpusVi(this.path, this.bytes, {this.png, this.sections, this.decoded, this.model, this.error});

  final String path;

  final Uint8List bytes;

  final Uint8List? png;

  final List<ViSection>? sections;

  final List<DecodedSection>? decoded;

  final ViModel? model;

  final Object? error;
}

CorpusVi parseCorpusVi(File file) {
  final raw = file.readAsBytesSync();
  final png = isPngBytes(raw) ? raw : null;
  final bytes = png == null ? raw : extractSnippetVi(raw) ?? raw;
  List<ViSection>? sections;
  List<DecodedSection>? decoded;
  ViModel? model;
  Object? error;
  try {
    sections = readViSections(bytes);
    decoded = [for (final section in sections) inflateSection(section)];
    model = buildViModelFromDecoded(decoded, subViNames: subViNamesOf(sections, bytes));
  } catch (e) {
    error = e;
  }
  return CorpusVi(file.path, bytes, png: png, sections: sections, decoded: decoded, model: model, error: error);
}

/// A law over the corpus: a top-level function applied to every VI, named for the timing table
/// and catalogued in corpus/laws.dart for the worker. Its result crosses isolate groups, so it is
/// built from primitives, lists and maps, never records or class instances.
class CorpusLaw<R> {
  const CorpusLaw(this.name, this.apply);

  final String name;

  final R Function(CorpusVi vi) apply;

  /// The law's results over [CorpusVis.files], in that order.
  Future<List<R>> get results async => (await corpusVis._results()).results[name]!.cast<R>();
}

extension CorpusCountLaw on CorpusLaw<Map<String, int>> {
  /// The files on which the law counted any of [keys], with those counts.
  Future<Map<String, Map<String, int>>> nonzero(Iterable<String> keys) async =>
      perFileNonzero(corpusVis.files, await results, keys);
}

/// The corpus laws applied in one pass: worker isolates, each in its own isolate group so their
/// heaps never block one another, parse a VI, run every catalogued law on it and drop it. The pass
/// starts when the first law's results are awaited.
class CorpusVis {
  List<File>? _files;

  List<File> get files => _files ??= listCorpusVis(corpusVi);

  Future<CorpusPass>? _pass;

  /// The seconds each law spent over the corpus, summed across workers, with 'parse' for the
  /// parse itself.
  Future<Map<String, double>> get lawSeconds async {
    final pass = await _results();
    return {
      'parse': pass.parseMicros / 1e6,
      for (final MapEntry(key: name, value: micros) in pass.lawMicros.entries) name: micros / 1e6,
    };
  }

  Future<CorpusPass> _results() => _pass ??= _run();

  Future<CorpusPass> _run() async {
    final test = Directory('${repoRoot().path}/packages/labwright_rsrc_parse/test');
    final dill = File('${Directory.systemTemp.createTempSync('corpus_worker').path}/corpus_worker.dill');
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '${test.path}/corpus_worker.dart',
      '-o',
      dill.path,
    ]);
    if (compiled.exitCode != 0) throw StateError('corpus worker failed to compile:\n${compiled.stderr}');
    final n = _workerCount < files.length ? _workerCount : files.length;
    final chunks = List.generate(n, (_) => <String>[]);
    for (var i = 0; i < files.length; i++) {
      chunks[i % n].add(files[i].path);
    }
    final packageConfig = File('${repoRoot().path}/.dart_tool/package_config.json').uri;
    final parts = await Future.wait([for (final chunk in chunks) _spawnWorker(dill.uri, packageConfig, chunk)]);
    dill.parent.deleteSync(recursive: true);
    final results = {
      for (final name in parts.first.results.keys)
        name: [for (var i = 0; i < files.length; i++) parts[i % n].results[name]![i ~/ n]],
    };
    return CorpusPass(
      results,
      parts.fold(0, (sum, part) => sum + part.parseMicros),
      {
        for (final name in parts.first.lawMicros.keys) name: parts.fold(0, (sum, part) => sum + part.lawMicros[name]!),
      },
    );
  }

  static Future<CorpusPass> _spawnWorker(Uri dill, Uri packageConfig, List<String> paths) async {
    final reply = ReceivePort();
    final exit = ReceivePort();
    final errors = ReceivePort();
    await Isolate.spawnUri(
      dill,
      paths,
      reply.sendPort,
      packageConfig: packageConfig,
      onExit: exit.sendPort,
      onError: errors.sendPort,
    );
    final outcome = await Future.any([
      reply.first,
      exit.first.then((_) => throw StateError('a corpus worker exited without replying')),
      errors.first.then((error) => throw StateError('a corpus worker died: ${(error as List).join('\n')}')),
    ]);
    reply.close();
    exit.close();
    errors.close();
    return switch (outcome as List<Object?>) {
      [final String failure] => throw StateError(failure),
      [final Map<String, List<Object?>> results, final int parseMicros, final Map<String, int> lawMicros] => CorpusPass(
        results,
        parseMicros,
        lawMicros,
      ),
      final other => throw StateError('unexpected corpus worker reply: $other'),
    };
  }
}

/// One worker's share of a pass: each law's results over its VIs, in order, and the time spent.
class CorpusPass {
  CorpusPass(this.results, this.parseMicros, this.lawMicros);

  final Map<String, List<Object?>> results;

  final int parseMicros;

  final Map<String, int> lawMicros;
}

final corpusVis = CorpusVis();

File corpusSnapshotFile() => File('${repoRoot().path}/packages/labwright_rsrc_parse/test/corpus_snapshot.json');

const snapshotRegenCommand = 'dart run packages/labwright_rsrc_parse/tool/snapshot.dart';

String corpusRelativePath(String path) {
  final root = '${corpusViDir.path}/';
  final normalized = path.replaceAll(r'\', '/');
  return normalized.startsWith(root) ? normalized.substring(root.length) : normalized;
}

Map<String, Map<String, int>> perFileNonzero(List<File> files, List<Map<String, int>> counts, Iterable<String> keys) {
  final out = <String, Map<String, int>>{};
  for (var i = 0; i < files.length; i++) {
    final nonzero = {
      for (final key in keys)
        if (counts[i][key] case final count? when count != 0) key: count,
    };
    if (nonzero.isNotEmpty) out[corpusRelativePath(files[i].path)] = nonzero;
  }
  return out;
}

bool isNonRsrcFixture(String path) => path.replaceAll(r'\', '/').endsWith('/rust-proxy/test_data/test.vi');

int get _workerCount => (Platform.numberOfProcessors - 2).clamp(1, 16);

Future<List<R>> corpusParallel<R>(List<File> files, R Function(Uint8List bytes, String path) perFile) async {
  if (files.isEmpty) return <R>[];
  final paths = files.map((f) => f.path).toList();
  final n = _workerCount < paths.length ? _workerCount : paths.length;
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % n].add(paths[i]);
  }
  final results = await Future.wait(
    chunks.map((chunk) => Isolate.run(() => [for (final p in chunk) perFile(readCorpusVi(File(p)), p)])),
  );
  return [for (var i = 0; i < paths.length; i++) results[i % n][i ~/ n]];
}

Future<List<(String, bool?)>> decodeSnippetPngs(Directory dir) async {
  final pngs = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return corpusParallel(pngs, (bytes, path) {
    if (isPngBytes(bytes)) return (path, null);
    final positioned = buildViModel(bytes).blockDiagrams.any((d) => d.objects.any((o) => o.absBounds != null));
    return (path, positioned);
  });
}
