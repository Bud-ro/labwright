import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

/// Corpus census of UNDECODED record-region bytes — the round-2 targeting
/// tool. Two views:
///
///  1. `--bails`: every bailed typedef body ([binaryTypeBodyExtents] rows with
///     a bail offset), aggregated by type name with undecoded mass (bail →
///     next head), so the biggest blocked body shapes rank first.
///  2. default: every [binaryUndecodedSpans] span, clustered by a leading
///     shape signature (first words: DELIM / zero / small int / pool ref),
///     aggregated by mass — the map of where the residual bytes sit.
///
/// Run from the package root:
///   dart run tool/undecoded_census.dart [corpusRoot] [--bails] [--top n]
String _defaultCorpusRoot() {
  const pkgRel = 'packages/labwright_seq/corpus';
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/$pkgRel/seq-sources.json').existsSync()) return '${d.path}/$pkgRel/seq';
    if (File('${d.path}/corpus/seq-sources.json').existsSync()) return '${d.path}/corpus/seq';
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return 'corpus/seq';
}

List<File> _binaryFiles(String root) {
  final out = <File>[];
  for (final f in Directory(root).listSync(recursive: true).whereType<File>()) {
    if (f.path.toLowerCase().endsWith('.seq')) out.add(f);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// Builds the ordered NUL string pool the record words reference by index.
List<String> _pool(Uint8List body, int recordRegionLength) {
  final pool = <String>[];
  var at = recordRegionLength;
  while (at < body.length) {
    final start = at;
    while (at < body.length && body[at] != 0) {
      at++;
    }
    pool.add(String.fromCharCodes(body, start, at));
    at++;
  }
  return pool;
}

bool _nameLike(String s) => s.isNotEmpty && s.length <= 40 && RegExp(r'^[A-Za-z_%][A-Za-z0-9_.%#\[\]]*$').hasMatch(s);

/// One signature token for a record word: delimiter, zero, small raw int,
/// name-like pool ref (kept verbatim — the cluster key), other pool ref, raw.
String _wordSig(int w, List<String> pool) {
  if (w == 0xffffffff) return 'D';
  if (w == 0) return '0';
  if (w < pool.length) {
    final s = pool[w];
    if (_nameLike(s)) return s;
    return w < 0x20 ? '$w' : '%STR';
  }
  return w < 0x100 ? '$w' : 'W';
}

void main(List<String> args) {
  var root = _defaultCorpusRoot();
  var bails = false;
  var bailShapes = false;
  var top = 40;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--bails') {
      bails = true;
    } else if (args[i] == '--bailshapes') {
      bailShapes = true;
    } else if (args[i] == '--top') {
      top = int.parse(args[++i]);
    } else {
      root = args[i];
    }
  }

  final files = _binaryFiles(root);
  if (bailShapes) {
    // shape at the bail offset → (count, mass, example)
    final byShape = <String, (int, int, String)>{};
    for (final f in files) {
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final body = inflateBinaryBody(bytes);
      final layout = analyzeBinaryBody(bytes);
      if (body == null || layout == null) continue;
      final pool = _pool(body, layout.recordRegionLength);
      final view = ByteData.sublistView(body);
      final extents = binaryTypeBodyExtents(bytes);
      for (var i = 0; i < extents.length; i++) {
        final e = extents[i];
        final bail = e.bail;
        if (bail == null || bail < 0) continue;
        final next = i + 1 < extents.length ? extents[i + 1].headAt : null;
        final mass = (next ?? e.bodyAt) - e.bodyAt;
        final sig = StringBuffer('${e.name}: ');
        for (var w = 0; w < 6 && bail + (w + 1) * 4 <= body.length; w++) {
          if (w > 0) sig.write(' ');
          sig.write(_wordSig(view.getUint32(bail + w * 4, Endian.little), pool));
        }
        final key = sig.toString();
        final cur = byShape[key] ?? (0, 0, '${f.path}@$bail');
        byShape[key] = (cur.$1 + 1, cur.$2 + mass, cur.$3);
      }
    }
    final rows = byShape.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    for (final r in rows.take(top)) {
      stdout.writeln(
        '${r.value.$2.toString().padLeft(9)} B ${r.value.$1.toString().padLeft(5)}x  ${r.key}\n'
        '            e.g. ${r.value.$3}',
      );
    }
    return;
  }
  if (bails) {
    // type name → (count, undecoded mass ≈ next-head − body start)
    final byName = <String, (int, int)>{};
    var totalMass = 0, totalCount = 0;
    for (final f in files) {
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final extents = binaryTypeBodyExtents(bytes);
      for (var i = 0; i < extents.length; i++) {
        final e = extents[i];
        if (e.bail == null) continue;
        final next = i + 1 < extents.length ? extents[i + 1].headAt : null;
        final mass = (next ?? e.bodyAt) - e.bodyAt;
        final cur = byName[e.name] ?? (0, 0);
        byName[e.name] = (cur.$1 + 1, cur.$2 + mass);
        totalCount++;
        totalMass += mass;
      }
    }
    final rows = byName.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    stdout.writeln('bailed typedef bodies: $totalCount, mass ~$totalMass B');
    for (final r in rows.take(top)) {
      stdout.writeln('${r.value.$2.toString().padLeft(9)} B ${r.value.$1.toString().padLeft(5)}x  ${r.key}');
    }
    return;
  }

  // shape signature → (span count, total bytes)
  final byShape = <String, (int, int)>{};
  var totalMass = 0, totalSpans = 0;
  for (final f in files) {
    final bytes = Uint8List.fromList(f.readAsBytesSync());
    if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
    final body = inflateBinaryBody(bytes);
    final layout = analyzeBinaryBody(bytes);
    if (body == null || layout == null) continue;
    final pool = _pool(body, layout.recordRegionLength);
    final view = ByteData.sublistView(body);
    final spans = binaryUndecodedSpans(bytes, max: 100000);
    for (final (start, end) in spans) {
      final sig = StringBuffer();
      for (var w = 0; w < 5 && start + (w + 1) * 4 <= end; w++) {
        if (w > 0) sig.write(' ');
        sig.write(_wordSig(view.getUint32(start + w * 4, Endian.little), pool));
      }
      final key = '${(end - start) < 16 ? "tiny " : ""}$sig';
      final cur = byShape[key] ?? (0, 0);
      byShape[key] = (cur.$1 + 1, cur.$2 + (end - start));
      totalSpans++;
      totalMass += end - start;
    }
  }
  final rows = byShape.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
  stdout.writeln('undecoded spans: $totalSpans, mass $totalMass B, shapes ${byShape.length}');
  for (final r in rows.take(top)) {
    stdout.writeln('${r.value.$2.toString().padLeft(9)} B ${r.value.$1.toString().padLeft(6)}x  ${r.key}');
  }
}
