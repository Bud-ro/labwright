// Corpus scanner: recursively parse every .vi/.ctl/.llb under a directory and
// report how many parsed, how many were cleanly rejected (ViFormatException),
// and how many CRASHED — i.e. parseVi threw something other than
// ViFormatException, which is always a bug. Handy for validating the reader
// against a folder of real VIs. Exits non-zero if any file crashed. Usage:
//   dart run packages/labwright_viparse/tool/scan_vis.dart <dir>
import 'dart:io';

import 'package:labwright_viparse/labwright_viparse.dart';

void main(List<String> args) {
  final root = args.isEmpty ? '.' : args.first;
  final files = Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) {
        final p = f.path.toLowerCase();
        return p.endsWith('.vi') || p.endsWith('.ctl') || p.endsWith('.llb');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var parsed = 0, rejected = 0, crashed = 0;
  var withBD = 0, withFP = 0, withCONP = 0, withSub = 0, named = 0;
  final crashes = <String>[];
  final samples = <String>[];

  for (final f in files) {
    try {
      final vi = parseVi(f.readAsBytesSync());
      parsed++;
      if (vi.hasBlockDiagram) withBD++;
      if (vi.hasFrontPanel) withFP++;
      if (vi.hasConnectorPane) withCONP++;
      if (vi.hasSubViLinks) withSub++;
      if (vi.name != null) named++;
      if (samples.length < 8) samples.add('${f.path.split('/').last}  ->  ${vi.describe()}');
    } on ViFormatException {
      rejected++; // handled cleanly — no crash
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
    ..writeln('  has connector pane: $withCONP')
    ..writeln('  has sub-VI links  : $withSub')
    ..writeln('  recovered a name  : $named')
    ..writeln('cleanly rejected (ViFormatException): $rejected')
    ..writeln('CRASHED (non-ViFormatException)     : $crashed');
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
