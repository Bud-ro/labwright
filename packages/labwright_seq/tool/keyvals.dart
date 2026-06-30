// Report the shape + sample values of nodes at given `Data`-tree paths across the
// corpus, to drive correct typed modeling (enum vs bool vs string vs container).
// Paths use the exact form tool/gaps.dart prints, e.g.
//   Data.Seq.[].Main.[].Measurement.Parameters.[].MessageType
// where `[]` matches every array element. For each path: className distribution
// and up to ~8 distinct scalar samples. Run: dart run tool/keyvals.dart <path>...
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

/// Resolve [segs] (path after the root) from [p], emitting (node, concretePath).
/// A `[]` segment matches every array element; a `*` segment matches every named
/// child and substitutes the child's name into the reported path.
void _resolve(SeqProperty p, List<String> segs, String concrete,
    void Function(SeqProperty, String) emit) {
  if (segs.isEmpty) {
    emit(p, concrete);
    return;
  }
  final seg = segs.first, rest = segs.sublist(1);
  if (seg == '[]') {
    for (final e in p.array ?? const <SeqProperty>[]) {
      _resolve(e, rest, '$concrete.[]', emit);
    }
  } else if (seg == '*') {
    for (final c in p.subProps) {
      _resolve(c, rest, '$concrete.${c.name}', emit);
    }
  } else {
    final c = p.prop(seg);
    if (c != null) _resolve(c, rest, '$concrete.$seg', emit);
  }
}

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
    if (fmt == SeqFormat.ini && bytes.length > 300 * 1024) continue;
    try {
      final sf = parseSeqFile(bytes);
      for (final path in args) {
        final segs = path.split('.');
        final after = segs.first == sf.data.name ? segs.sublist(1) : segs;
        _resolve(sf.data, after, sf.data.name, (p, concrete) {
          counts.update(concrete, (n) => n + 1, ifAbsent: () => 1);
          final cls = p.isArray
              ? 'Array[${p.array?.length ?? 0}]'
              : p.subProps.isNotEmpty
                  ? 'Container{${p.subProps.length}}'
                  : (p.className ?? '?');
          (classDist[concrete] ??= {}).update(cls, (n) => n + 1, ifAbsent: () => 1);
          final v = p.scalar;
          final s = samples[concrete] ??= {};
          if (v != null && v.isNotEmpty && s.length < 8) {
            s.add(v.length > 50 ? '${v.substring(0, 50)}…' : v);
          }
        });
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
