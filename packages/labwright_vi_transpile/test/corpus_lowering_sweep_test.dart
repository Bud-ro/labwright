@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'corpus_snapshot.dart';

void main() {
  test('every corpus VI and snippet keeps exactly its snapshotted lowering', () async {
    final want = File(
      corpusSnapshotPath,
    ).readAsLinesSync().where((l) => l.startsWith('{')).map((l) => l.replaceAll(RegExp(r',$'), ''));
    final got = (await corpusSweep()).lines;
    final missing = want.toSet().difference(got.toSet()), added = got.toSet().difference(want.toSet());
    expect(
      missing.isEmpty && added.isEmpty,
      isTrue,
      reason: 'regenerate with `dart run tool/snapshot.dart`\n- ${missing.join('\n- ')}\n+ ${added.join('\n+ ')}',
    );
  });
  test('subVI calls bind through the connector pane in the caller\'s own direction', () async {
    expect((await corpusSweep()).directionDisagreements, isEmpty);
  });
  test('every emitted library analyzes clean at the recommended lint set, and compiles', () async {
    final scratch = _scratchPackage((await corpusSweep()).sources);
    try {
      final analyzed = Process.runSync(_kDart, [
        'analyze',
        '--fatal-infos',
        '${scratch.path}/lib',
      ], workingDirectory: scratch.path);
      expect(analyzed.exitCode, 0, reason: 'the emitted code is not clean:\n${analyzed.stdout}${analyzed.stderr}');
      final compiled = Process.runSync(_kDart, [
        'compile',
        'kernel',
        'bin/all.dart',
        '-o',
        '${scratch.path}/all.dill',
      ], workingDirectory: scratch.path);
      expect(compiled.exitCode, 0, reason: 'the emitted code does not compile:\n${compiled.stdout}${compiled.stderr}');
    } finally {
      scratch.deleteSync(recursive: true);
    }
  });
}

final String _kDart = Platform.resolvedExecutable;

const String _kScratchPackageName = 'lv_emitted';

Directory _scratchPackage(Set<String> sources) {
  final dir = Directory.systemTemp.createTempSync('lv_emitted_');
  for (final sub in const ['lib', 'bin', '.dart_tool']) {
    Directory('${dir.path}/$sub').createSync();
  }
  final names = <String>[];
  for (final source in sources) {
    final name = 'vi_${names.length.toString().padLeft(4, '0')}.dart';
    File('${dir.path}/lib/$name').writeAsStringSync(source);
    names.add(name);
  }
  File('${dir.path}/bin/all.dart').writeAsStringSync(
    '${[
      for (var i = 0; i < names.length; i++) "import 'package:$_kScratchPackageName/${names[i]}' as vi$i;",
    ].join('\n')}\n\nvoid main() {}\n',
  );

  final configUri = Isolate.packageConfigSync!;
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages']! as List<dynamic>).cast<Map<String, dynamic>>();
  for (final package in packages) {
    package['rootUri'] = configUri.resolve(package['rootUri']! as String).toString();
  }
  final runtime = packages.firstWhere((package) => package['name'] == kLvRuntimePackage);
  packages.add({
    'name': _kScratchPackageName,
    'rootUri': dir.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': runtime['languageVersion'],
  });
  File('${dir.path}/.dart_tool/package_config.json').writeAsStringSync(jsonEncode(config));
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: $_kScratchPackageName\n'
    'environment:\n  sdk: ^${runtime['languageVersion']}.0\n'
    'dependencies:\n  $kLvRuntimePackage: any\n',
  );
  File('${dir.path}/analysis_options.yaml').writeAsStringSync('include: package:lints/recommended.yaml\n');
  return dir;
}
