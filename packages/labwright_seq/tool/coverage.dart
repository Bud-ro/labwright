import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

/// TestStand XML model-coverage report — the sibling of the VI coverage tool.
///
/// Walks the fetched corpus (`corpus/seq/`), and for each XML `.seq` reports how
/// much of the `Data` property tree the typed lens surfaces (`modeled/total`).
/// Prints a per-source + total table and writes a gitignored `corpus/seq/REPORT.md`
/// so the scorecard is regenerated from the live decoders, never hand-maintained.
///
/// Run: `dart run tool/coverage.dart [corpusRoot=<package>/corpus/seq]`
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

class _Stat {
  int files = 0, seqs = 0, steps = 0;
  var cov = const SeqCoverage(total: 0, modeled: 0);
}

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : _defaultCorpusRoot();
  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    stderr.writeln('corpus not found: $root (run tool/fetch_seq_corpus.dart)');
    exit(1);
  }

  final bySource = <String, List<File>>{};
  for (final src in rootDir.listSync().whereType<Directory>()) {
    final name = src.path.split('/').last;
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.seq')) (bySource[name] ??= []).add(f);
    }
  }

  // Format census over every .seq — formatDetected% is the first coverage axis:
  // a file we cannot classify is a file we understand nothing about. (See
  // COVERAGE.md for the full axis list.)
  var nTotal = 0, nXml = 0, nIni = 0, nBinary = 0, nUnknown = 0;
  for (final fs in bySource.values) {
    for (final f in fs) {
      nTotal++;
      switch (detectSeqFormat(f.readAsBytesSync())) {
        case SeqFormat.xml:
          nXml++;
        case SeqFormat.ini:
          nIni++;
        case SeqFormat.binary:
          nBinary++;
        case SeqFormat.unknown:
          nUnknown++;
      }
    }
  }
  String pct(int a, int b) => b == 0 ? '0.0' : (100 * a / b).toStringAsFixed(1);

  final overall = _Stat();
  final md = StringBuffer()
    ..writeln('| source | XML .seq | sequences | steps | modeled | total | model% |')
    ..writeln('|---|--:|--:|--:|--:|--:|--:|');
  stdout.writeln('source                              xml  seqs steps  modeled  total  model%');
  for (final src in bySource.keys.toList()..sort()) {
    final s = _measure(bySource[src]!, SeqFormat.xml);
    overall
      ..files += s.files
      ..seqs += s.seqs
      ..steps += s.steps
      ..cov = overall.cov + s.cov;
    stdout.writeln('${src.padRight(34).substring(0, 34)} ${s.files.toString().padLeft(4)} '
        '${s.seqs.toString().padLeft(5)} ${s.steps.toString().padLeft(5)} '
        '${s.cov.modeled.toString().padLeft(8)} ${s.cov.total.toString().padLeft(6)} '
        '${(s.cov.ratio * 100).toStringAsFixed(1).padLeft(6)}');
    md.writeln('| $src | ${s.files} | ${s.seqs} | ${s.steps} | ${s.cov.modeled} | '
        '${s.cov.total} | ${(s.cov.ratio * 100).toStringAsFixed(1)} |');
  }
  stdout.writeln('-' * 76);
  stdout.writeln('TOTAL ${overall.files} XML .seq · ${overall.seqs} sequences · ${overall.steps} steps · '
      'model coverage ${(overall.cov.ratio * 100).toStringAsFixed(1)}% '
      '(${overall.cov.modeled}/${overall.cov.total} property nodes)');

  // The legacy INI encoding maps onto the same SeqProperty model, so the same
  // lens + coverage metric apply. Measured separately (it is a different, older
  // format): its raw tree is larger because each step INLINES its step-type
  // definition (DescriptionFormat/DefaultNameFormat/CodeTemplates/Group/…), which
  // the XML form keeps centralized in <typelist> — so the % is lower without any
  // missing per-step instance data. INI files >300KB are skipped (OOM guard).
  final iniFiles = [for (final fs in bySource.values) ...fs];
  final ini = _measure(iniFiles, SeqFormat.ini);
  stdout.writeln('INI   ${ini.files} INI .seq · ${ini.seqs} sequences · ${ini.steps} steps · '
      'model coverage ${(ini.cov.ratio * 100).toStringAsFixed(1)}% '
      '(${ini.cov.modeled}/${ini.cov.total} property nodes)');

  // The complete, declared-up-front axis set (see COVERAGE.md). A .seq is fully
  // understood IFF every axis is 100%. The binary axis is the big frontier: TOF1
  // binary files are detected and recon'd (strings/names) but their record grammar
  // is NOT decoded, so binaryModel% is honestly 0 — stated here, not hidden.
  stdout.writeln('-' * 76);
  stdout.writeln('AXES (all must reach 100% for "fully understood"):');
  stdout.writeln('  formatDetected%  ${pct(nTotal - nUnknown, nTotal)}  '
      '($nXml xml, $nIni ini, $nBinary binary, $nUnknown unknown of $nTotal .seq)');
  stdout.writeln('  xmlModel%        ${(overall.cov.ratio * 100).toStringAsFixed(1)}  (typed-lens nodes over XML Data trees)');
  stdout.writeln('  iniModel%        ${(ini.cov.ratio * 100).toStringAsFixed(1)}  (typed-lens nodes over INI Data trees)');
  stdout.writeln('  binaryModel%     0.0  (FRONTIER: $nBinary binary .seq, record grammar not yet decoded)');

  final report = StringBuffer()
    ..writeln('# TestStand XML model — coverage report card')
    ..writeln()
    ..writeln('Auto-generated by `packages/labwright_seq/tool/coverage.dart`. '
        'Gitignored — do not hand-edit. Run the tool to refresh.')
    ..writeln()
    ..writeln('**model%** = fraction of `Data`-tree property nodes the typed lens '
        '(SeqFile/Sequence/Step/StepSettings/StepModule/SeqVariable) surfaces. '
        'The remainder is still available as the raw `SeqProperty` tree.')
    ..writeln()
    ..writeln(md.toString().trimRight())
    ..writeln()
    ..writeln('**TOTAL (XML)** ${overall.files} XML .seq · ${overall.seqs} sequences · '
        '${overall.steps} steps · model coverage '
        '${(overall.cov.ratio * 100).toStringAsFixed(1)}% '
        '(${overall.cov.modeled}/${overall.cov.total} property nodes).')
    ..writeln()
    ..writeln('**TOTAL (INI, legacy)** ${ini.files} INI .seq · ${ini.seqs} sequences · '
        '${ini.steps} steps · model coverage '
        '${(ini.cov.ratio * 100).toStringAsFixed(1)}% '
        '(${ini.cov.modeled}/${ini.cov.total} property nodes). Lower than XML '
        'because each step inlines its step-type definition (kept in `<typelist>` '
        'for XML); no per-step instance data is missing. Files >300KB skipped.');
  File('$root/REPORT.md').writeAsStringSync('$report\n');
  stdout.writeln('wrote $root/REPORT.md');
}

_Stat _measure(List<File> files, SeqFormat fmt) {
  final s = _Stat();
  for (final f in files..sort((a, b) => a.path.compareTo(b.path))) {
    // INI files can be very large; skip >300KB to avoid the parser OOMing.
    if (fmt == SeqFormat.ini && f.lengthSync() > 300 * 1024) continue;
    final bytes = f.readAsBytesSync();
    if (detectSeqFormat(bytes) != fmt) continue;
    final SeqFile sf;
    try {
      sf = parseSeqFile(bytes);
    } catch (_) {
      continue;
    }
    s.files++;
    s.seqs += sf.sequences.length;
    s.steps += sf.sequences.fold(0, (a, q) => a + q.steps.length);
    s.cov = s.cov + measureCoverage(sf);
  }
  return s;
}
