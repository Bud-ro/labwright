// Report the shape + sample values of given step properties across the corpus,
// to drive correct typed modeling (enum vs bool vs string vs container). For
// each key, prints className distribution and up to ~8 distinct scalar samples.
// Keys prefixed `TS.` look under the step's TS object; otherwise at step level.
// Run: dart run tool/keyvals.dart <key> [key...]
import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

String _root() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/packages/labwright_seq/corpus/seq-sources.json').existsSync()) {
      return '${d.path}/packages/labwright_seq/corpus/seq';
    }
    if (File('${d.path}/corpus/seq-sources.json').existsSync()) return '${d.path}/corpus/seq';
    d = d.parent;
  }
  return 'corpus/seq';
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: keyvals <key> [key...]  (key or TS.key)');
    exit(1);
  }
  final classDist = {for (final k in args) k: <String, int>{}};
  final samples = {for (final k in args) k: <String>{}};
  final counts = {for (final k in args) k: 0};

  SeqProperty? lookup(Step s, String key) {
    if (key.startsWith('TS.')) return s.raw.prop('TS')?.prop(key.substring(3));
    return s.raw.prop(key);
  }

  for (final f in Directory(_root()).listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = f.readAsBytesSync();
    final fmt = detectSeqFormat(bytes);
    if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
    if (fmt == SeqFormat.ini && bytes.length > 300 * 1024) continue;
    try {
      final sf = parseSeqFile(bytes);
      for (final seq in sf.sequences) {
        for (final step in seq.steps) {
          for (final k in args) {
            final p = lookup(step, k);
            if (p == null) continue;
            counts[k] = counts[k]! + 1;
            final cls = p.isArray
                ? 'Array[${p.array?.length ?? 0}]'
                : p.subProps.isNotEmpty
                    ? 'Container{${p.subProps.length}}'
                    : (p.className ?? '?');
            classDist[k]!.update(cls, (n) => n + 1, ifAbsent: () => 1);
            final v = p.scalar;
            if (v != null && v.isNotEmpty && samples[k]!.length < 8) {
              samples[k]!.add(v.length > 50 ? '${v.substring(0, 50)}…' : v);
            }
          }
        }
      }
    } catch (_) {}
  }
  for (final k in args) {
    stdout.writeln('\n$k  (seen ${counts[k]}×)');
    stdout.writeln('  classes: ${classDist[k]}');
    if (samples[k]!.isNotEmpty) stdout.writeln('  samples: ${samples[k]!.join(" | ")}');
  }
}
