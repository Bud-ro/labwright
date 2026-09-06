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

List<(SeqProperty, String)> _resolve(SeqProperty p, List<String> segs, String concrete) {
  if (segs.isEmpty) return [(p, concrete)];
  final seg = segs.first, rest = segs.sublist(1);
  if (seg == '[]') {
    return [for (final e in p.array ?? const <SeqProperty>[]) ..._resolve(e, rest, '$concrete.[]')];
  } else if (seg == '*') {
    return [for (final c in p.subProps) ..._resolve(c, rest, '$concrete.${c.name}')];
  } else {
    final c = p.prop(seg);
    return c != null ? _resolve(c, rest, '$concrete.$seg') : const [];
  }
}

String _classLabel(SeqProperty p) => p.isArray
    ? 'Array[${p.array?.length ?? 0}]'
    : p.subProps.isNotEmpty
    ? 'Container{${p.subProps.length}}'
    : (p.className ?? '?');

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: keyvals <Data.path.with.[].segments>...');
    exit(1);
  }
  final classDist = <String, Map<String, int>>{};
  final samples = <String, Set<String>>{};
  final counts = <String, int>{};

  for (final f in Directory(_root()).listSync(recursive: true).whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.seq')) continue;
    final bytes = f.readAsBytesSync();
    final fmt = detectSeqFormat(bytes);
    if (fmt != SeqFormat.xml && fmt != SeqFormat.ini) continue;
    try {
      final sf = parseSeqFile(bytes);
      for (final path in args) {
        final segs = path.split('.');
        final after = segs.first == sf.data.name ? segs.sublist(1) : segs;
        for (final (p, concrete) in _resolve(sf.data, after, sf.data.name)) {
          counts.update(concrete, (n) => n + 1, ifAbsent: () => 1);
          final cls = _classLabel(p);
          (classDist[concrete] ??= {}).update(cls, (n) => n + 1, ifAbsent: () => 1);
          final v = p.scalar;
          final s = samples[concrete] ??= {};
          if (v != null && v.isNotEmpty && s.length < 8) {
            s.add(v.length > 50 ? '${v.substring(0, 50)}…' : v);
          }
        }
      }
    } catch (_) {}
  }
  final keys = counts.keys.toList()..sort();
  for (final k in keys) {
    stdout.writeln('\n$k  (seen ${counts[k]}×)');
    stdout.writeln('  classes: ${classDist[k]}');
    if (samples[k]!.isNotEmpty) stdout.writeln('  samples: ${samples[k]!.join(" | ")}');
  }
}
