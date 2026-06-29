import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// VI corpus **coverage** report — the honest, complete scorecard for "how much
/// of a `.vi` do we understand?".
///
/// The north star (CLAUDE.md) is *total understanding of every byte*. That goal
/// is decomposed into independent axes, each a real 0–100% where 100% means that
/// axis is genuinely done — and the set is laid out up front so reaching 100% on
/// one is never "okay, now part 2". The format is fully understood IFF every axis
/// below is 100%. See `packages/labwright_rsrc_parse/COVERAGE.md` for the full
/// taxonomy.
///
///   parseOk%           — VIs whose RSRC container parses (reader totality).
///   decodeOk%          — VIs whose compressed sections all inflate.
///   containerExact%    — VIs whose container serializes back byte-identically
///                        (round-trip). 100% ⟺ the container wrapper is understood.
///   blocksIdentified%  — block instances whose 4-char tag is catalogued (vs an
///                        unknown tag). 100% ⟺ every block is identified by type.
///   blockBytesDecoded% — block-content bytes (inflated) belonging to a block type
///                        that has a decoder. 100% ⟺ every block has decode logic
///                        (byte-weighted). This is the "how much is left" headline.
///   Heap internals (refine blockBytesDecoded for the C4 record heaps, the bulk):
///   heapFramed%        — heap body bytes inside a deliberately-framed record.
///   heapSemantic%      — heap body bytes in a record assigned a typed meaning.
///   heapComplete%      — heaps walked exactly to EOF.
///
/// The numbers are never hand-maintained: this tool computes them over the WHOLE
/// corpus and writes `corpus/baseline.json` (the regression floor read by
/// `corpus_coverage_test.dart`) and a gitignored `corpus/vi/REPORT.md` scorecard.
///
/// Run: `dart run tool/coverage.dart [corpusRoot=<package>/corpus/vi]`
const _heapTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

/// The gitignored VI corpus checked out by tool/fetch_corpus.dart, under this
/// package's `corpus/vi/`. Resolved from CWD (the run may start at the repo root
/// or the package dir) by checking the package-relative and package-local
/// locations; the committed baseline.json is written next to it.
String _defaultCorpusRoot() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}/$pkgRel/sources.json').existsSync()) return '${d.path}/$pkgRel/vi';
    if (File('${d.path}/corpus/sources.json').existsSync()) return '${d.path}/corpus/vi';
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return 'corpus/vi';
}

class _Stat {
  int vis = 0, parseOk = 0, decOk = 0, containerExact = 0, objVIs = 0;
  int heaps = 0, fullHeaps = 0;
  int framed = 0, body = 0, semantic = 0, valueKind = 0; // heap byte tiers
  int blockInstances = 0, blocksIdentified = 0; // block identification
  int blockBytes = 0, blockBytesDecoded = 0; // block-content byte decode

  static double _r(int a, int b) => b == 0 ? 0 : a / b;
  double get parseOkPct => _r(parseOk, vis);
  double get decodeOkPct => _r(decOk, vis);
  double get containerExactPct => _r(containerExact, vis);
  double get blocksIdentifiedPct => _r(blocksIdentified, blockInstances);
  double get blockBytesDecodedPct => _r(blockBytesDecoded, blockBytes);
  // Heap byte tiers (kept under the historical key names in baseline.json).
  double get deliberatelyParsed => _r(framed, body);
  double get semanticallyDecoded => _r(semantic, body);
  double get valueKindKnown => _r(valueKind, body);
  double get classified => _r(semantic + valueKind, body);
  double get fullyParsedHeaps => _r(fullHeaps, heaps);

  void add(_Stat s) {
    vis += s.vis;
    parseOk += s.parseOk;
    decOk += s.decOk;
    containerExact += s.containerExact;
    objVIs += s.objVIs;
    heaps += s.heaps;
    fullHeaps += s.fullHeaps;
    framed += s.framed;
    body += s.body;
    semantic += s.semantic;
    valueKind += s.valueKind;
    blockInstances += s.blockInstances;
    blocksIdentified += s.blocksIdentified;
    blockBytes += s.blockBytes;
    blockBytesDecoded += s.blockBytesDecoded;
  }
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
    try {
      if (_listEq(ViContainer.parse(bytes).toBytes(), bytes)) s.containerExact++;
    } catch (_) {}
    final List<DecodedSection> secs;
    try {
      secs = decodeSections(bytes);
      s.decOk++;
    } catch (_) {
      continue;
    }
    var objs = 0;
    for (final sec in secs) {
      // Block identification + byte-weighted decode coverage (every section).
      s.blockInstances++;
      if (isCataloguedTag(sec.tag)) s.blocksIdentified++;
      s.blockBytes += sec.bytes.length;
      if (blockInfo(sec.tag).isDecoded) s.blockBytesDecoded += sec.bytes.length;

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

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _pct(double v) => (v * 100).toStringAsFixed(1);

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : _defaultCorpusRoot();
  // Flat layout: each immediate subdir of the corpus root is one pinned source
  // (`<owner>_<name>/`); group VIs by that source dir. The WHOLE corpus is
  // measured — no per-source cap and no single pinned sample.
  final bySource = <String, List<File>>{};
  final rootDir = Directory(root);
  if (rootDir.existsSync()) {
    for (final src in rootDir.listSync().whereType<Directory>()) {
      final name = src.path.split('/').last;
      for (final f in src.listSync(recursive: true).whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.vi')) continue;
        (bySource[name] ??= <File>[]).add(f);
      }
    }
  }

  final overall = _Stat();
  final md = StringBuffer()
    ..writeln('| source | VIs | parse% | decode% | container% | idBlk% | decBytes% | heapFramed% | heapSemantic% | heapComplete% |')
    ..writeln('|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|');
  stdout.writeln('source             VIs parse% decode% cont% idBlk% decByt% hFram% hSem% hCompl%');
  for (final src in bySource.keys.toList()..sort()) {
    final files = bySource[src]!..sort((a, b) => a.path.compareTo(b.path));
    final s = _measure(files);
    overall.add(s);
    stdout.writeln(
      '${src.padRight(16).substring(0, 16)} ${s.vis.toString().padLeft(4)} '
      '${_pct(s.parseOkPct).padLeft(5)} ${_pct(s.decodeOkPct).padLeft(6)} '
      '${_pct(s.containerExactPct).padLeft(5)} ${_pct(s.blocksIdentifiedPct).padLeft(5)} '
      '${_pct(s.blockBytesDecodedPct).padLeft(6)} ${_pct(s.deliberatelyParsed).padLeft(5)} '
      '${_pct(s.semanticallyDecoded).padLeft(5)} ${_pct(s.fullyParsedHeaps).padLeft(6)}',
    );
    md.writeln(
      '| $src | ${s.vis} | ${_pct(s.parseOkPct)} | ${_pct(s.decodeOkPct)} | ${_pct(s.containerExactPct)} | '
      '${_pct(s.blocksIdentifiedPct)} | ${_pct(s.blockBytesDecodedPct)} | ${_pct(s.deliberatelyParsed)} | '
      '${_pct(s.semanticallyDecoded)} | ${_pct(s.fullyParsedHeaps)} |',
    );
  }
  stdout.writeln('-' * 78);
  final total = 'TOTAL ${overall.vis} VIs · parse ${_pct(overall.parseOkPct)}% · '
      'decode ${_pct(overall.decodeOkPct)}% · container-exact ${_pct(overall.containerExactPct)}% · '
      'blocks-identified ${_pct(overall.blocksIdentifiedPct)}% · '
      'block-bytes-decoded ${_pct(overall.blockBytesDecodedPct)}% · '
      'heap-framed ${_pct(overall.deliberatelyParsed)}% · '
      'heap-semantic ${_pct(overall.semanticallyDecoded)}% '
      '(+${_pct(overall.valueKindKnown)}% value-kind = ${_pct(overall.classified)}% classified) · '
      'heap-complete ${_pct(overall.fullyParsedHeaps)}%';
  stdout.writeln(total);

  if (rootDir.existsSync()) {
    final report = StringBuffer()
      ..writeln('# VI corpus coverage — report card')
      ..writeln()
      ..writeln('Auto-generated by `packages/labwright_rsrc_parse/tool/coverage.dart` over the '
          'whole corpus. Gitignored — do not hand-edit. Run the tool to refresh. See '
          '`COVERAGE.md` for what each axis means and why 100%-on-all = fully understood.')
      ..writeln()
      ..writeln('- **parse%** — VIs whose RSRC container parses.')
      ..writeln('- **decode%** — VIs whose compressed sections all inflate.')
      ..writeln('- **container%** — VIs that serialize back byte-identically (round-trip).')
      ..writeln('- **idBlk%** — block instances whose tag is catalogued.')
      ..writeln('- **decBytes%** — block-content bytes in a block type with a decoder.')
      ..writeln('- **heapFramed/heapSemantic/heapComplete%** — heap body framing / typed-meaning / walked-to-EOF.')
      ..writeln('- Heaps measured: ${_heapTags.join(', ')}.')
      ..writeln()
      ..writeln(md.toString().trimRight())
      ..writeln()
      ..writeln('**$total**');
    File('$root/REPORT.md').writeAsStringSync('$report\n');
    stdout.writeln('wrote $root/REPORT.md');
  }

  // Record the whole-corpus figures as the test's regression floor — never
  // hand-typed. Every axis is here so the floor is the complete picture.
  if (overall.vis > 0) {
    final baseline = {
      'generatedBy': 'packages/labwright_rsrc_parse/tool/coverage.dart',
      'scope': 'whole VI corpus (corpus/vi); see COVERAGE.md for the metric taxonomy',
      'metrics': {
        'parseOk': 'VIs whose RSRC container parses / total VIs',
        'decodeOk': 'VIs whose sections all inflate / total VIs',
        'containerExact': 'VIs whose ViContainer round-trips byte-exactly / total VIs',
        'blocksIdentified': 'block instances with a catalogued tag / all block instances',
        'blockBytesDecoded': 'inflated block bytes in a block type with a decoder / all block bytes',
        'deliberatelyParsed': 'heap body bytes inside a deliberately-framed record / heap body bytes',
        'semanticallyDecoded': 'heap body bytes with a typed meaning / heap body bytes',
        'valueKindKnown': 'heap body bytes with known value-kind but unknown meaning / heap body bytes',
        'fullyParsedHeaps': 'heaps walked exactly to EOF / heaps',
        'note': 'Each is 0..1; the VI format is fully understood IFF every axis is 1.0.',
      },
      'corpus': {
        'vis': overall.vis,
        'parseOk': double.parse(overall.parseOkPct.toStringAsFixed(4)),
        'decodeOk': double.parse(overall.decodeOkPct.toStringAsFixed(4)),
        'containerExact': double.parse(overall.containerExactPct.toStringAsFixed(4)),
        'blocksIdentified': double.parse(overall.blocksIdentifiedPct.toStringAsFixed(4)),
        'blockBytesDecoded': double.parse(overall.blockBytesDecodedPct.toStringAsFixed(4)),
        'deliberatelyParsed': double.parse(overall.deliberatelyParsed.toStringAsFixed(4)),
        'semanticallyDecoded': double.parse(overall.semanticallyDecoded.toStringAsFixed(4)),
        'valueKindKnown': double.parse(overall.valueKindKnown.toStringAsFixed(4)),
        'fullyParsedHeaps': double.parse(overall.fullyParsedHeaps.toStringAsFixed(4)),
      },
    };
    final out = File('${rootDir.parent.path}/baseline.json');
    out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baseline)}\n');
    stdout.writeln('wrote ${out.path}');
  }
}
