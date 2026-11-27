import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

import '../test/corpus_dirs.dart';

class _Path {
  int seen = 0, read = 0;
  final Map<String, int> unreadValues = {};
  final Set<String> files = {};
}

void main(List<String> args) {
  final corpus = Directory('${corpusSeqDir.path}/seq-corpus');
  final projects = <String, List<File>>{
    for (final source in Directory('${corpus.path}/sources').listSync().whereType<Directory>())
      source.path.split('/').last: [
        for (final f in source.listSync(recursive: true).whereType<File>())
          if (f.path.toLowerCase().endsWith('.seq')) f,
      ],
    for (final f in Directory('${corpus.path}/rosetta').listSync().whereType<File>())
      if (f.path.toLowerCase().endsWith('.seq')) 'rosetta/${f.path.split('/').last}': [f],
  };
  final paths = <String, _Path>{};
  for (final MapEntry(key: project, value: files) in projects.entries) {
    final parsed = {for (final f in files) f.path.substring(corpus.path.length + 1): parseSeqFile(f.readAsBytesSync())};
    final reads = Set<SeqProperty>.identity();
    seqScalarReads = reads;
    exportSeqProjectToDart(parsed);
    seqScalarReads = null;
    for (final MapEntry(key: name, value: file) in parsed.entries) {
      void walk(String key, SeqProperty p, Set<SeqProperty> skip) {
        if (skip.contains(p)) return;
        if (p.subProps.isEmpty && p.array == null) {
          final value = p.scalar;
          if (value == null) return;
          final entry = paths[key] ??= _Path();
          entry.seen++;
          entry.files.add('$project/$name');
          if (reads.contains(p)) {
            entry.read++;
          } else {
            final shown = value.length > 60 ? '${value.substring(0, 60)}…' : value;
            entry.unreadValues[shown] = (entry.unreadValues[shown] ?? 0) + 1;
          }
          return;
        }
        for (final c in p.subProps) {
          walk('$key.${c.name}', c, skip);
        }
        for (final e in p.array ?? const <SeqProperty>[]) {
          walk('$key[]', e, skip);
        }
      }

      final stepNodes = Set<SeqProperty>.identity();
      final sequenceNodes = Set<SeqProperty>.identity();
      for (final sequence in file.sequences) {
        sequenceNodes.add(sequence.raw);
        for (final step in sequence.steps) {
          stepNodes.add(step.raw);
          walk('step ${step.type ?? '?'} ${step.module.adapter.name}:', step.raw, const {});
        }
      }
      for (final sequence in file.sequences) {
        walk('sequence:', sequence.raw, stepNodes);
      }
      walk('file:', file.data, sequenceNodes);
    }
  }
  final out = StringBuffer();
  for (final key in paths.keys.toList()..sort()) {
    final p = paths[key]!;
    final unread = p.seen - p.read;
    final values = p.unreadValues.entries.toList()..sort((a, b) => b.value - a.value);
    out.writeln(
      [
        key,
        p.seen,
        p.read,
        unread,
        p.files.length,
        values.take(6).map((e) => '${e.key.replaceAll(RegExp(r'\s+'), ' ')}=${e.value}').join(' | '),
      ].join('\t'),
    );
  }
  File(args.isEmpty ? 'export_audit.tsv' : args.first).writeAsStringSync(out.toString());
}
