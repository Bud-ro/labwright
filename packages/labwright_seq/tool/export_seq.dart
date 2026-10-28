import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';

/// Exports the text sequence files of a source tree, with the VIs their steps call, as a Dart
/// package: `dart run tool/export_seq.dart <source tree> <output directory> [--package=<name>]`.
void main(List<String> args) {
  final positional = args.where((argument) => !argument.startsWith('--')).toList();
  final options = {
    for (final argument in args.where((argument) => argument.startsWith('--')))
      argument.split('=').first: argument.contains('=') ? argument.substring(argument.indexOf('=') + 1) : '',
  };
  if (positional.length != 2) {
    stderr.writeln('usage: dart run tool/export_seq.dart [--package=<name>] <source tree> <output directory>');
    exit(64);
  }
  final root = Directory(positional[0]);
  final out = Directory(positional[1]);
  if (!root.existsSync()) {
    stderr.writeln('${root.path}: no such directory');
    exit(66);
  }
  final packages = Directory.fromUri(Platform.script.resolve('../..'));
  final export = exportSeqTree(
    root,
    packageName: options['--package'] ?? seqSnakeCase(root.absolute.uri.pathSegments.where((s) => s.isNotEmpty).last),
    pathDependencies: {
      for (final package in const ['labwright', 'labwright_lv_runtime'])
        package: seqRelativeDirectory(from: out.absolute.path, to: '${packages.absolute.path}/$package'),
    },
  );
  export.write(out);
  final measures = export.measures;
  stdout
    ..writeln('${export.files.length} files written to ${out.path}')
    ..writeln(
      'sequence files: ${measures.sequenceFiles} exported, ${measures.unparsedSequenceFiles} not parsed',
    )
    ..writeln(
      'LabVIEW steps: ${measures.labViewSteps} · ${measures.stepsLowered} call a lowered VI · '
      '${measures.stepsStubbed} call a refused VI · ${measures.stepsWithoutDiagram} name a VI without a '
      'block diagram · unlocated ${measures.stepsUnlocated.map((kind, n) => MapEntry(kind.name, n))}',
    )
    ..writeln(
      'VIs: ${measures.viFunctions} emitted · ${measures.viLowered} lowered · ${measures.viStubbed} refused '
      '${measures.refusalsByKind} · ${measures.declarations} declarations',
    );
}
