import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Corpus validator for Stage 1b (decode): inflates every block section under a
/// directory of `.vi`/`.ctl`/`.llb` files and reports how many inflated, total
/// decompressed bytes, BDEx heap sizes, and any crashes (must be zero).
///
/// Usage: `dart run packages/labwright_rsrc_parse/tool/scan_decode.dart <dir>`
void main(List<String> args) {
  final root = args.isEmpty ? '.' : args.first;
  final files = Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi') ||
          f.path.toLowerCase().endsWith('.ctl') ||
          f.path.toLowerCase().endsWith('.llb'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var ok = 0, crashed = 0, sections = 0, inflated = 0, decBytes = 0;
  var withVersion = 0, withTitle = 0, withStrings = 0;
  final bdSizes = <int>[];
  final crashes = <String>[];
  for (final f in files) {
    try {
      final bytes = f.readAsBytesSync();
      final secs = decodeSections(bytes);
      ok++;
      sections += secs.length;
      for (final s in secs) {
        if (s.wasCompressed) {
          inflated++;
          decBytes += s.length;
          if (s.tag == 'BDEx') bdSizes.add(s.length);
        }
      }
      final v = decodeVersion(bytes);
      if (v.version != null) withVersion++;
      if (v.title != null) withTitle++;
      if (extractHeapStrings(bytes).isNotEmpty) withStrings++;
    } catch (e) {
      crashed++;
      if (crashes.length < 20) crashes.add('${f.path}: ${e.runtimeType}: $e');
    }
  }

  stdout
    ..writeln('files            : ${files.length}')
    ..writeln('decoded ok       : $ok')
    ..writeln('CRASHED          : $crashed')
    ..writeln('total sections   : $sections')
    ..writeln('  inflated       : $inflated')
    ..writeln('  decompressed MB: ${(decBytes / (1024 * 1024)).toStringAsFixed(1)}')
    ..writeln('--- metadata (Stage 2) ---')
    ..writeln('with LabVIEW version: $withVersion/$ok')
    ..writeln('with VIDS title     : $withTitle/$ok')
    ..writeln('with heap strings   : $withStrings/$ok');
  if (bdSizes.isNotEmpty) {
    bdSizes.sort();
    stdout.writeln('BDEx decompressed: n=${bdSizes.length} min=${bdSizes.first} '
        'max=${bdSizes.last} median=${bdSizes[bdSizes.length ~/ 2]}');
  }
  for (final c in crashes) {
    stdout.writeln('  $c');
  }
  if (crashed > 0) exitCode = 1;
}
