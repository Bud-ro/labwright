@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';
import 'package:test/test.dart';

import '../../../tool/corpus.dart';

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// For one file: the sections the text form builds against the ones read, and the file it
/// encodes read back; the keys that failed, with the file.
Map<String, int> _check(String path) {
  final c = <String, int>{};
  void bad(String k) => c[k] = (c[k] ?? 0) + 1;
  var bytes = File(path).readAsBytesSync();
  if (isPngBytes(bytes)) bytes = extractSnippetVi(bytes) ?? bytes;
  final List<DecodedSection> sections;
  try {
    sections = decodeSections(bytes);
  } catch (_) {
    return c;
  }
  final spec = viSpecOf(bytes);
  if (spec.sections.length != sections.length) {
    bad('count');
    return c;
  }
  for (var i = 0; i < sections.length; i++) {
    final built = spec.sections[i];
    if (built.tag != sections[i].tag || built.index != sections[i].index) {
      bad('tag');
    }
    if (built.compressed != sections[i].wasCompressed) bad('envelope');
    if (!_same(built.payload, sections[i].bytes)) {
      bad('payload.\${built.runtimeType}');
    }
  }
  final List<DecodedSection> again;
  try {
    again = decodeSections(spec.encode());
  } catch (_) {
    bad('file');
    return c;
  }
  if (again.length != sections.length) {
    bad('file.count');
  } else {
    for (var i = 0; i < again.length; i++) {
      final same =
          again[i].tag == sections[i].tag &&
          _same(again[i].bytes, sections[i].bytes);
      if (!same) bad('file.section');
    }
  }
  return c;
}

Future<Map<String, Map<String, int>>> _sweep(List<File> files) async {
  final n = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(n, (_) => <String>[]);
  for (var i = 0; i < files.length; i++) {
    chunks[i % n].add(files[i].path);
  }
  final parts = await Future.wait([
    for (final chunk in chunks)
      Isolate.run(
        () => {
          for (final path in chunk)
            if (_check(path) case final bad when bad.isNotEmpty) path: bad,
        },
      ),
  ]);
  return {for (final part in parts) ...part};
}

void main() {
  test(
    'every corpus VI builds back from its text form section for section, and as a file',
    () async {
      final files = [
        ...corpusFiles(corpusVi, '.vi'),
        ...corpusFiles(corpusVi, '.ctl'),
        ...corpusFiles(corpusVi, '.png'),
      ];
      final bad = await _sweep(files);
      expect({
        for (final MapEntry(key: path, value: keys) in bad.entries)
          path.substring(corpusVi.path.length + 1): keys,
      }, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
