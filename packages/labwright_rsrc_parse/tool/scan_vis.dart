import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Corpus scanner: recursively parses every `.vi`/`.ctl`/`.llb` under a directory
/// and reports how many parsed, how many were cleanly rejected
/// (`ViFormatException`), and how many CRASHED — i.e. `parseVi` threw something
/// other than `ViFormatException`, which is always a bug. Handy for validating the
/// reader against a folder of real VIs. Exits non-zero if any file crashed.
///
/// Usage: `dart run packages/labwright_rsrc_parse/tool/scan_vis.dart <dir>`
void main(List<String> args) {
  final root = args.isEmpty ? '.' : args.first;
  final files =
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => const ['.vi', '.ctl', '.llb'].any(f.path.toLowerCase().endsWith))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var parsed = 0, rejected = 0, crashed = 0;
  var withBD = 0, withFP = 0, withConnectorPane = 0, withSub = 0, named = 0;
  var totalSections = 0, filesWithBdSection = 0, sectionCrashes = 0;
  final crashes = <String>[];
  final samples = <String>[];

  for (final f in files) {
    final bytes = f.readAsBytesSync();
    try {
      final secs = readViSections(bytes);
      totalSections += secs.length;
      if (secs.any((s) => s.tag == 'BDHb' || s.tag == 'BDEx')) filesWithBdSection++;
    } catch (e) {
      sectionCrashes++;
      if (crashes.length < 20) crashes.add('${f.path} [sections]: ${e.runtimeType}: $e');
    }
    try {
      final vi = parseVi(bytes);
      parsed++;
      if (vi.hasBlockDiagram) withBD++;
      if (vi.hasFrontPanel) withFP++;
      if (vi.hasConnectorPane) withConnectorPane++;
      if (vi.hasSubViLinks) withSub++;
      if (vi.name != null) named++;
      if (samples.length < 8) samples.add('${f.path.split('/').last}  ->  ${vi.describe()}');
    } on ViFormatException {
      rejected++;
    } catch (e) {
      crashed++;
      if (crashes.length < 20) crashes.add('${f.path}: ${e.runtimeType}: $e');
    }
  }

  stdout
    ..writeln('files scanned : ${files.length}')
    ..writeln('parsed OK     : $parsed')
    ..writeln('  has block diagram : $withBD')
    ..writeln('  has front panel   : $withFP')
    ..writeln('  has connector pane: $withConnectorPane')
    ..writeln('  has sub-VI links  : $withSub')
    ..writeln('  recovered a name  : $named')
    ..writeln('cleanly rejected (ViFormatException): $rejected')
    ..writeln('CRASHED (non-ViFormatException)     : $crashed')
    ..writeln('--- sections (Stage 1) ---')
    ..writeln('total sections extracted : $totalSections')
    ..writeln('files with BD section     : $filesWithBdSection')
    ..writeln('section extraction crashes: $sectionCrashes');
  if (samples.isNotEmpty) {
    stdout.writeln('\nsample summaries:');
    for (final s in samples) {
      stdout.writeln('  $s');
    }
  }
  if (crashes.isNotEmpty) {
    stdout.writeln('\nCRASHES (must be empty):');
    for (final c in crashes) {
      stdout.writeln('  $c');
    }
    exitCode = 1;
  }
}
