import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

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
///
/// The gitignored corpus checkout lives under the package's `corpus/vi/`
/// (resolved by the shared [corpusBaseDir]); the committed baseline.json is
/// written next to it.

class _Stat {
  int vis = 0, parseOk = 0, decOk = 0, containerExact = 0;
  int heaps = 0, fullHeaps = 0;
  int framed = 0, body = 0, semantic = 0, valueKind = 0;
  int blockInstances = 0, blocksIdentified = 0;
  int blockBytes = 0, blockBytesDecoded = 0;

  static double _ratio(int a, int b) => b == 0 ? 0 : a / b;
  double get parseOkPct => _ratio(parseOk, vis);
  double get decodeOkPct => _ratio(decOk, vis);
  double get containerExactPct => _ratio(containerExact, vis);
  double get blocksIdentifiedPct => _ratio(blocksIdentified, blockInstances);
  double get blockBytesDecodedPct => _ratio(blockBytesDecoded, blockBytes);
  double get deliberatelyParsed => _ratio(framed, body);
  double get semanticallyDecoded => _ratio(semantic, body);
  double get valueKindKnown => _ratio(valueKind, body);
  double get classified => _ratio(semantic + valueKind, body);
  double get fullyParsedHeaps => _ratio(fullHeaps, heaps);

  void add(_Stat s) {
    vis += s.vis;
    parseOk += s.parseOk;
    decOk += s.decOk;
    containerExact += s.containerExact;
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
    for (final sec in secs) {
      s.blockInstances++;
      if (isCataloguedTag(sec.tag)) s.blocksIdentified++;
      s.blockBytes += sec.bytes.length;
      if (blockInfo(sec.tag).isDecoded) s.blockBytesDecoded += sec.bytes.length;

      if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
      final tiers = measureHeapTiers(sec.bytes, sec.tag);
      s.framed += tiers.walk.coveredBytes;
      s.body += tiers.walk.bodyBytes;
      s.heaps++;
      if (tiers.walk.complete) s.fullHeaps++;
      s.semantic += tiers.semanticBytes;
      s.valueKind += tiers.valueKindBytes;
    }
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
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final rootDir = Directory(root);
  // One recursive, symlink-free enumeration (the same [listCorpusVis] the corpus
  // tests use), grouped by source = the first path segment under the root. A
  // `.vi` directly under the root has no source dir and is not counted.
  final bySource = <String, List<File>>{};
  final prefix = '${rootDir.path}/';
  for (final f in listCorpusVis(rootDir)) {
    final rel = f.path.startsWith(prefix) ? f.path.substring(prefix.length) : f.path;
    final slash = rel.indexOf('/');
    if (slash <= 0) continue;
    (bySource[rel.substring(0, slash)] ??= <File>[]).add(f);
  }

  final overall = _Stat();
  final md = StringBuffer()
    ..writeln(
      '| source | VIs | parse% | decode% | container% | idBlk% | decBytes% | heapFramed% | heapSemantic% | heapComplete% |',
    )
    ..writeln('|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|');
  stdout.writeln('source             VIs parse% decode% cont% idBlk% decByt% hFram% hSem% hCompl%');
  for (final src in bySource.keys.toList()..sort()) {
    final s = _measure(bySource[src]!);
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
  final total =
      'TOTAL ${overall.vis} VIs · parse ${_pct(overall.parseOkPct)}% · '
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
      ..writeln(
        'Auto-generated by `packages/labwright_rsrc_parse/tool/coverage.dart` over the '
        'whole corpus. Gitignored — do not hand-edit. Run the tool to refresh. See '
        '`COVERAGE.md` for what each axis means and why 100%-on-all = fully understood.',
      )
      ..writeln()
      ..writeln('- **parse%** — VIs whose RSRC container parses.')
      ..writeln('- **decode%** — VIs whose compressed sections all inflate.')
      ..writeln('- **container%** — VIs that serialize back byte-identically (round-trip).')
      ..writeln('- **idBlk%** — block instances whose tag is catalogued.')
      ..writeln('- **decBytes%** — block-content bytes in a block type with a decoder.')
      ..writeln('- **heapFramed/heapSemantic/heapComplete%** — heap body framing / typed-meaning / walked-to-EOF.')
      ..writeln('- Heaps measured: ${kHeapSectionTags.join(', ')}.')
      ..writeln()
      ..writeln(md.toString().trimRight())
      ..writeln()
      ..writeln('**$total**');
    File('$root/REPORT.md').writeAsStringSync('$report\n');
    stdout.writeln('wrote $root/REPORT.md');
  }

  if (overall.vis > 0) {
    double round4(double v) => double.parse(v.toStringAsFixed(4));
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
        'parseOk': round4(overall.parseOkPct),
        'decodeOk': round4(overall.decodeOkPct),
        'containerExact': round4(overall.containerExactPct),
        'blocksIdentified': round4(overall.blocksIdentifiedPct),
        'blockBytesDecoded': round4(overall.blockBytesDecodedPct),
        'deliberatelyParsed': round4(overall.deliberatelyParsed),
        'semanticallyDecoded': round4(overall.semanticallyDecoded),
        'valueKindKnown': round4(overall.valueKindKnown),
        'fullyParsedHeaps': round4(overall.fullyParsedHeaps),
      },
    };
    final out = File('${rootDir.parent.path}/baseline.json');
    out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baseline)}\n');
    stdout.writeln('wrote ${out.path}');
  }
}
