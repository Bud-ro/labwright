import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

/// Corpus **deliberately-parsed** benchmark — the mechanical metric to ratchet
/// upward (see corpus/README.md).
///
/// "% deliberately parsed" = the fraction of object/type-heap
/// (`BDHb`/`BDHP`/`FPHb`/`FPHP`/`DTHP`) body bytes that fall inside a record the
/// walker **deliberately frames** (a specific `recordSkip` case), as opposed to
/// the bytes after the first opcode it does not yet handle. It is a *framing*
/// metric (boundaries recognized), not a claim that every value is decoded.
///
/// The number is never hand-maintained: this tool computes it and writes the
/// deterministic picotech-sample figure to `corpus/baseline.json`, which
/// `corpus_coverage_test.dart` reads as a regression floor.
///
/// Run: `dart run tool/coverage.dart [corpusRoot=/tmp/claude-1000] [perSourceCap=120]`
const _heapTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

class _Stat {
  int vis = 0, parseOk = 0, decOk = 0, objVIs = 0, framed = 0, body = 0, heaps = 0, fullHeaps = 0;
  int semantic = 0; // bytes in records we assign a typed MEANING to (tier 2)
  int valueKind = 0; // bytes where the value KIND is known but the meaning is not (tier 1)
  double get deliberatelyParsed => body == 0 ? 0 : framed / body;
  double get semanticallyDecoded => body == 0 ? 0 : semantic / body;
  double get valueKindKnown => body == 0 ? 0 : valueKind / body;
  double get classified => body == 0 ? 0 : (semantic + valueKind) / body;
  double get fullyParsedHeaps => heaps == 0 ? 0 : fullHeaps / heaps;
}

_Stat _measure(List<File> files) {
  final s = _Stat();
  for (final f in files) {
    s.vis++;
    final Uint8List bytes;
    try {
      bytes = f.readAsBytesSync();
      parseVi(bytes);
      s.parseOk++;
    } catch (_) {
      continue;
    }
    final List<DecodedSection> secs;
    try {
      secs = decodeSections(bytes);
      s.decOk++;
    } catch (_) {
      continue;
    }
    var objs = 0;
    for (final sec in secs) {
      if (!_heapTags.contains(sec.tag) || sec.bytes.length < 6) continue;
      final w = walkHeapBody(sec.bytes);
      s.framed += w.coveredBytes;
      s.body += w.bodyBytes;
      s.heaps++;
      if (w.complete) s.fullHeaps++;
      for (final span in w.spans) {
        switch (heapDecodeTier(sec.bytes, span.offset, span.lead, sec.tag)) {
          case HeapDecodeTier.semantic:
            s.semantic += span.length;
          case HeapDecodeTier.valueKindKnown:
            s.valueKind += span.length;
          case HeapDecodeTier.framed:
            break;
        }
      }
      try {
        objs += buildDiagram(sec.bytes, sectionTag: sec.tag).objects.length;
      } catch (_) {}
    }
    if (objs > 0) s.objVIs++;
  }
  return s;
}

List<File> _vis(Directory dir, int cap) => (dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.toLowerCase().endsWith('.vi'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path)))
    .take(cap)
    .toList();

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : '/tmp/claude-1000';
  final cap = args.length > 1 ? int.parse(args[1]) : 120;
  final bySource = <String, List<File>>{};
  for (final d in ['vi_samples', 'vi_diverse']) {
    final dir = Directory('$root/$d');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.vi')) continue;
      final rel = f.path.substring(dir.path.length + 1);
      (bySource[d == 'vi_samples' ? 'picotech' : rel.split('/').first] ??= <File>[]).add(f);
    }
  }

  final overall = _Stat();
  stdout.writeln('source            VIs parseOK decOK objVIs  heaps  delib% semantic% vKind% fullHeaps%');
  for (final src in bySource.keys.toList()..sort()) {
    final files = (bySource[src]!..sort((a, b) => a.path.compareTo(b.path))).take(cap).toList();
    final s = _measure(files);
    overall
      ..vis += s.vis
      ..parseOk += s.parseOk
      ..decOk += s.decOk
      ..objVIs += s.objVIs
      ..framed += s.framed
      ..semantic += s.semantic
      ..valueKind += s.valueKind
      ..body += s.body
      ..heaps += s.heaps
      ..fullHeaps += s.fullHeaps;
    stdout.writeln('${src.padRight(16)} ${s.vis.toString().padLeft(4)} ${s.parseOk.toString().padLeft(6)} '
        '${s.decOk.toString().padLeft(5)} ${s.objVIs.toString().padLeft(6)} ${s.heaps.toString().padLeft(6)} '
        '${(s.deliberatelyParsed * 100).toStringAsFixed(1).padLeft(6)} ${(s.semanticallyDecoded * 100).toStringAsFixed(1).padLeft(8)} '
        '${(s.valueKindKnown * 100).toStringAsFixed(1).padLeft(6)} ${(s.fullyParsedHeaps * 100).toStringAsFixed(1).padLeft(9)}');
  }
  stdout.writeln('-' * 78);
  stdout.writeln('TOTAL ${overall.vis} VIs · parse ${(100 * overall.parseOk / overall.vis).toStringAsFixed(1)}% · '
      'decode ${(100 * overall.decOk / overall.vis).toStringAsFixed(1)}% · objVIs ${overall.objVIs} · '
      'deliberately-parsed ${(overall.deliberatelyParsed * 100).toStringAsFixed(1)}% · '
      'semantically-decoded ${(overall.semanticallyDecoded * 100).toStringAsFixed(1)}% '
      '(+${(overall.valueKindKnown * 100).toStringAsFixed(1)}% value-kind-known = ${(overall.classified * 100).toStringAsFixed(1)}% classified) · '
      'fully-parsed heaps ${(overall.fullyParsedHeaps * 100).toStringAsFixed(1)}%');

  // Mechanically record the deterministic picotech-first-60 figure as the test's
  // regression floor — never hand-typed.
  final pico = Directory('$root/vi_samples');
  if (pico.existsSync()) {
    final s = _measure(_vis(pico, 60));
    final baseline = {
      'generatedBy': 'packages/labwright_videcode/tool/coverage.dart',
      'metric': 'deliberatelyParsed = framed bytes / total; semanticallyDecoded = typed-MEANING bytes / total (excludes kindOnly value-kind labels); valueKindKnown = kind-known-but-meaning-unknown bytes / total. Heaps BDHb/BDHP/FPHb/FPHP/DTHP.',
      'picotechFirst60': {
        'vis': s.vis,
        'parseOk': s.parseOk,
        'decodeOk': s.decOk,
        'heaps': s.heaps,
        'deliberatelyParsed': double.parse(s.deliberatelyParsed.toStringAsFixed(4)),
        'semanticallyDecoded': double.parse(s.semanticallyDecoded.toStringAsFixed(4)),
        'valueKindKnown': double.parse(s.valueKindKnown.toStringAsFixed(4)),
        'fullyParsedHeaps': double.parse(s.fullyParsedHeaps.toStringAsFixed(4)),
      },
    };
    final out = File('../../corpus/baseline.json');
    out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baseline)}\n');
    stdout.writeln('wrote ${out.path} (picotech-first-60 semantically-decoded '
        '${(s.semanticallyDecoded * 100).toStringAsFixed(1)}%, +${(s.valueKindKnown * 100).toStringAsFixed(1)}% value-kind-known)');
  }
}
