import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Run: `dart run tool/snapshot.dart [corpusDir]` (writes `<pkg>/corpus/snapshot.json`)

void main(List<String> args) {
  final base = corpusBaseDir().path;
  final dir = Directory(args.isNotEmpty ? args[0] : '$base/vi');
  if (!dir.existsSync()) {
    stderr.writeln('corpus dir not found: ${dir.path}');
    exit(1);
  }
  final vis = listCorpusVis(dir);

  final root = '${dir.path}/';
  final files = <String, List<Map<String, dynamic>>>{};
  final blockSet = <String, List<String>>{};
  final errors = <Map<String, dynamic>>[];
  for (final f in vis) {
    final name = f.path.startsWith(root) ? f.path.substring(root.length).replaceAll('\\', '/') : f.path;
    try {
      final bytes = f.readAsBytesSync();
      final blocks = parseVi(bytes).blocks.toSet().toList()..sort();
      final m = buildViModel(bytes);
      final gk = blocks.join(',');
      blockSet[gk] = blocks;
      (files[gk] ??= []).add({
        'name': name,
        'fp': m.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
        'bd': m.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
      });
    } catch (e) {
      errors.add({'name': name, 'error': e.toString()});
    }
  }
  final groupKeys = blockSet.keys.toList()..sort();
  for (final list in files.values) {
    list.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  }
  errors.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final buf = StringBuffer()
    ..writeln('{')
    ..writeln('  "generatedBy": "packages/labwright_rsrc_parse/tool/snapshot.dart",')
    ..writeln('  "groups": [');
  for (var gi = 0; gi < groupKeys.length; gi++) {
    final gk = groupKeys[gi];
    final gtail = gi == groupKeys.length - 1 ? '' : ',';
    buf
      ..writeln('    {')
      ..writeln('      "blocks": ${jsonEncode(blockSet[gk])},')
      ..writeln('      "files": [');
    final list = files[gk]!;
    for (var fi = 0; fi < list.length; fi++) {
      buf.writeln('        ${jsonEncode(list[fi])}${fi == list.length - 1 ? '' : ','}');
    }
    buf
      ..writeln('      ]')
      ..writeln('    }$gtail');
  }
  buf
    ..writeln('  ],')
    ..writeln('  "errors": [');
  for (var ei = 0; ei < errors.length; ei++) {
    buf.writeln('    ${jsonEncode(errors[ei])}${ei == errors.length - 1 ? '' : ','}');
  }
  buf
    ..writeln('  ]')
    ..writeln('}');
  File('$base/snapshot.json').writeAsStringSync(buf.toString());
  final nFiles = files.values.fold<int>(0, (a, g) => a + g.length);
  stdout.writeln('snapshot: $nFiles VIs in ${groupKeys.length} block-set groups · ${errors.length} errors');
}
