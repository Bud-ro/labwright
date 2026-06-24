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
  int semantic = 0; // bytes in records we assign a typed MEANING to (not just framed)
  double get deliberatelyParsed => body == 0 ? 0 : framed / body;
  double get semanticallyDecoded => body == 0 ? 0 : semantic / body;
  double get fullyParsedHeaps => heaps == 0 ? 0 : fullHeaps / heaps;
}

/// Whether the record at [o] is *semantically decoded* — we extract a typed
/// meaning — vs merely framed (boundary known, meaning not). This is the deeper
/// frontier the "deliberately parsed" framing metric doesn't capture.
bool _isSemantic(Uint8List b, int o, int lead, String tag) {
  // Object header (class + oid), group open/close (bracket tree), child ref.
  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) &&
      o + 9 <= b.length && b[o + 2] == 0x02 && b[o + 3] == 0xfe && b[o + 6] == 0xfd) {
    return true;
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) return true; // close
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    if (o + 4 <= b.length && (b[o + 3] == 0xfb || b[o + 3] == 0xfe || b[o + 3] == 0xfd)) return true; // group open
  }
  if (lead == 0x14 && decodeHeapRef(b, o) != null) return true; // typed object reference (any subop but the 0x53 literal)
  // C4 records: decoded when the opcode has confirmed semantics.
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(b, o, tag);
    return rec != null && rec.kind.isDecoded;
  }
  // Attribute records: decoded when the id is named in the catalog.
  final a = decodeHeapAttr(b, o);
  if (a != null) return a.attribute != HeapAttribute.unknown;
  // Named property tokens (the catalogued hi<=1 family) and the 0x04
  // type-descriptor grammar (role known = structural). Tagged sub-lists with a
  // 10/11/12/13 lead are already counted above as group-opens; this adds the
  // bare selectors and the 0x04 fragments.
  if (decodeHeapPropertyToken(b, o) != null || isTypeDescriptorToken(lead)) return true;
  return false; // framed-only (meaning still undecoded)
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
        if (_isSemantic(sec.bytes, span.offset, span.lead, sec.tag)) s.semantic += span.length;
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
  stdout.writeln('source            VIs parseOK decOK objVIs  heaps  delib% semantic% fullHeaps%');
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
      ..body += s.body
      ..heaps += s.heaps
      ..fullHeaps += s.fullHeaps;
    stdout.writeln('${src.padRight(16)} ${s.vis.toString().padLeft(4)} ${s.parseOk.toString().padLeft(6)} '
        '${s.decOk.toString().padLeft(5)} ${s.objVIs.toString().padLeft(6)} ${s.heaps.toString().padLeft(6)} '
        '${(s.deliberatelyParsed * 100).toStringAsFixed(1).padLeft(6)} ${(s.semanticallyDecoded * 100).toStringAsFixed(1).padLeft(8)} ${(s.fullyParsedHeaps * 100).toStringAsFixed(1).padLeft(9)}');
  }
  stdout.writeln('-' * 72);
  stdout.writeln('TOTAL ${overall.vis} VIs · parse ${(100 * overall.parseOk / overall.vis).toStringAsFixed(1)}% · '
      'decode ${(100 * overall.decOk / overall.vis).toStringAsFixed(1)}% · objVIs ${overall.objVIs} · '
      'deliberately-parsed ${(overall.deliberatelyParsed * 100).toStringAsFixed(1)}% · '
      'semantically-decoded ${(overall.semanticallyDecoded * 100).toStringAsFixed(1)}% · '
      'fully-parsed heaps ${(overall.fullyParsedHeaps * 100).toStringAsFixed(1)}%');

  // Mechanically record the deterministic picotech-first-60 figure as the test's
  // regression floor — never hand-typed.
  final pico = Directory('$root/vi_samples');
  if (pico.existsSync()) {
    final s = _measure(_vis(pico, 60));
    final baseline = {
      'generatedBy': 'packages/labwright_videcode/tool/coverage.dart',
      'metric': 'deliberatelyParsed = framed bytes / total; semanticallyDecoded = typed-meaning bytes / total. Heaps BDHb/BDHP/FPHb/FPHP/DTHP.',
      'picotechFirst60': {
        'vis': s.vis,
        'parseOk': s.parseOk,
        'decodeOk': s.decOk,
        'heaps': s.heaps,
        'deliberatelyParsed': double.parse(s.deliberatelyParsed.toStringAsFixed(4)),
        'semanticallyDecoded': double.parse(s.semanticallyDecoded.toStringAsFixed(4)),
        'fullyParsedHeaps': double.parse(s.fullyParsedHeaps.toStringAsFixed(4)),
      },
    };
    final out = File('../../corpus/baseline.json');
    out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baseline)}\n');
    stdout.writeln('wrote ${out.path} (picotech-first-60 deliberately-parsed '
        '${(s.deliberatelyParsed * 100).toStringAsFixed(1)}%)');
  }
}
