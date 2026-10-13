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

/// Every corpus VI parsed once per test process and kept in worker isolates; a law runs over all
/// of them, in corpus order, where they live.
class CorpusVis {
  List<File>? _files;

  List<File> get files => _files ??= listCorpusVis(corpusVi);

  Future<List<_Worker>>? _workers;

  /// [law] applied to every VI, in [files] order; it must be a top-level function.
  Future<List<R>> map<R>(R Function(CorpusVi vi) law) async {
    final workers = await (_workers ??= _spawn(files));
    final replies = await Future.wait([for (final worker in workers) worker.run(law)]);
    final n = workers.length;
    return [for (var i = 0; i < files.length; i++) replies[i % n][i ~/ n] as R];
  }

  /// The files on which [law] counts any of [keys], with those counts.
  Future<Map<String, Map<String, int>>> validateAll(
    Map<String, int> Function(CorpusVi vi) law,
    Iterable<String> keys,
  ) async => perFileNonzero(files, await map(law), keys);

  Future<void> close() async {
    final workers = await _workers;
    if (workers == null) return;
    for (final worker in workers) {
      worker.commands.send(null);
    }
    _workers = null;
  }

  static Future<List<_Worker>> _spawn(List<File> files) {
    final n = _workerCount < files.length ? _workerCount : files.length;
    final chunks = List.generate(n, (_) => <String>[]);
    for (var i = 0; i < files.length; i++) {
      chunks[i % n].add(files[i].path);
    }
    return Future.wait([for (final chunk in chunks) _Worker.spawn(chunk)]);
  }
}

final corpusVis = CorpusVis();

class _Worker {
  _Worker(this.commands);

  final SendPort commands;

  static Future<_Worker> spawn(List<String> paths) async {
    final ready = ReceivePort();
    await Isolate.spawn(_main, (ready.sendPort, paths));
    final commands = await ready.first as SendPort;
    ready.close();
    return _Worker(commands);
  }

  Future<List<Object?>> run(Function law) async {
    final reply = ReceivePort();
    commands.send((law, reply.sendPort));
    final (results, failure) = await reply.first as (List<Object?>?, String?);
    reply.close();
    if (results == null) throw StateError(failure!);
    return results;
  }

  static void _main((SendPort, List<String>) init) {
    final (ready, paths) = init;
    final vis = [for (final path in paths) parseCorpusVi(File(path))];
    final commands = ReceivePort();
    ready.send(commands.sendPort);
    commands.listen((message) {
      if (message == null) {
        commands.close();
        return;
      }
      final (law, reply) = message as (Function, SendPort);
      final results = <Object?>[];
      for (final vi in vis) {
        try {
          results.add(law(vi));
        } catch (error, stack) {
          reply.send((null, 'the law threw on ${vi.path}: $error\n$stack'));
          return;
        }
      }
      reply.send((results, null));
    });
  }
}

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
