import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Run: `dart run tool/snapshot.dart [corpusDir]` (writes `<pkg>/corpus/snapshot.json`)

typedef _Counts = ({String name, int fp, int bd});

typedef _Group = ({List<String> blocks, List<_Counts> files});

typedef _Failure = ({String name, String error});

void main(List<String> args) {
  final base = corpusBaseDir().path;
  final dir = Directory(args.isNotEmpty ? args[0] : '$base/vi');
  if (!dir.existsSync()) {
    stderr.writeln('corpus dir not found: ${dir.path}');
    exit(1);
  }
  final vis = listCorpusVis(dir);

  final root = '${dir.path}/';
  final groups = <String, _Group>{};
  final errors = <_Failure>[];
  for (final file in vis) {
    final name = file.path.startsWith(root) ? file.path.substring(root.length).replaceAll('\\', '/') : file.path;
    try {
      final bytes = file.readAsBytesSync();
      final blocks = parseVi(bytes).blocks.toSet().toList()..sort();
      final model = buildViModel(bytes);
      (groups[blocks.join(',')] ??= (blocks: blocks, files: [])).files.add((
        name: name,
        fp: model.frontPanelDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
        bd: model.blockDiagrams.fold<int>(0, (a, b) => a + b.objects.length),
      ));
    } catch (e) {
      errors.add((name: name, error: e.toString()));
    }
  }
  final ordered = groups.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in ordered) {
    entry.value.files.sort((a, b) => a.name.compareTo(b.name));
  }
  errors.sort((a, b) => a.name.compareTo(b.name));

  final buf = StringBuffer()
    ..writeln('{')
    ..writeln('  "generatedBy": "packages/labwright_rsrc_parse/tool/snapshot.dart",')
    ..writeln('  "groups": [');
  for (var gi = 0; gi < ordered.length; gi++) {
    final group = ordered[gi].value;
    buf
      ..writeln('    {')
      ..writeln('      "blocks": ${jsonEncode(group.blocks)},')
      ..writeln('      "files": [');
    for (var fi = 0; fi < group.files.length; fi++) {
      final file = group.files[fi];
      final row = jsonEncode({'name': file.name, 'fp': file.fp, 'bd': file.bd});
      buf.writeln('        $row${fi == group.files.length - 1 ? '' : ','}');
    }
    buf
      ..writeln('      ]')
      ..writeln('    }${gi == ordered.length - 1 ? '' : ','}');
  }
  buf
    ..writeln('  ],')
    ..writeln('  "errors": [');
  for (var ei = 0; ei < errors.length; ei++) {
    final row = jsonEncode({'name': errors[ei].name, 'error': errors[ei].error});
    buf.writeln('    $row${ei == errors.length - 1 ? '' : ','}');
  }
  buf
    ..writeln('  ]')
    ..writeln('}');
  File('$base/snapshot.json').writeAsStringSync(buf.toString());
  final nFiles = groups.values.fold<int>(0, (a, g) => a + g.files.length);
  stdout.writeln('snapshot: $nFiles VIs in ${groups.length} block-set groups · ${errors.length} errors');
}
