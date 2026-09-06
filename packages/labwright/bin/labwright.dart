import 'dart:io';
import 'dart:math';

import 'package:labwright/src/restart_code.dart';
import 'package:labwright/src/source_hash.dart' show localDirectiveUris;

Future<void> main(List<String> args) async {
  final rest = [...args];
  final command = rest.isEmpty ? 'run' : rest.removeAt(0);
  switch (command) {
    case 'run':
      exitCode = await _run(rest);
    case 'scan':
      exitCode = _scan(rest);
    case 'init':
      exitCode = _init(rest);
    case '--help' || '-h' || 'help':
      stdout.writeln(_usage);
    default:
      exitCode = await _run([command, ...rest]);
  }
}

const _usage = '''
usage: labwright run [target] [--seed N|random]
                     [--total-shards N --shard-index I]
                     [--port N] [--no-viewer] [--report out.json]
                     [--keep-open|--interactive]
       labwright scan [dir]
       labwright init [dir]''';

Future<int> _run(List<String> args) async {
  final rest = [...args];
  String? target;
  final defines = <String>[];
  var linger = false;
  while (rest.isNotEmpty) {
    final arg = rest.removeAt(0);
    switch (arg) {
      case '--seed':
        final raw = rest.isEmpty ? '' : rest.removeAt(0);
        final seed = raw == 'random' ? Random().nextInt(1 << 31) : int.tryParse(raw) ?? 0;
        defines.add('-Dlabwright.seed=$seed');
      case '--total-shards':
        defines.add(
          '-Dlabwright.totalShards='
          '${int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? 1}',
        );
      case '--shard-index':
        defines.add(
          '-Dlabwright.shardIndex='
          '${int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? 0}',
        );
      case '--port':
        defines.add(
          '-Dlabwright.port='
          '${int.tryParse(rest.isEmpty ? '' : rest.removeAt(0)) ?? 1212}',
        );
      case '--no-viewer':
        defines.add('-Dlabwright.viewer=false');
      case '--no-identity':
        defines.add('-Dlabwright.identity=false');
      case '--report':
        if (rest.isNotEmpty) {
          defines.add('-Dlabwright.report=${rest.removeAt(0)}');
        }
      case '--keep-open':
        defines.add('-Dlabwright.keepOpen=true');
        linger = true;
      case '--interactive':
        defines.add('-Dlabwright.interactive=true');
        linger = true;
      case '--help' || '-h':
        stdout.writeln(_usage);
        return 0;
      default:
        target = arg;
    }
  }
  final path = _resolveTarget(target);
  if (path == null) {
    stderr
      ..writeln(
        '[Labwright]: no suite found '
        '(expected ${target ?? 'e2e/main.dart'})',
      )
      ..writeln('run `labwright init` to generate the example e2e/ folder');
    return 64;
  }

  while (true) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        if (linger) ...['--enable-vm-service=0', '-Dlabwright.supervised=true'],
        ...defines,
        path,
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    final signals = [
      ProcessSignal.sigint.watch().listen((_) => process.kill(ProcessSignal.sigint)),
      if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => process.kill()),
    ];
    final code = await process.exitCode;
    for (final s in signals) {
      await s.cancel();
    }
    if (!linger || code != restartExitCode) return code;
    stdout.writeln('[Labwright]: hot restart - starting a fresh suite process');
  }
}

String? _resolveTarget(String? target) {
  final candidate = target ?? 'e2e';
  if (FileSystemEntity.isDirectorySync(candidate)) {
    final main = '$candidate${Platform.pathSeparator}main.dart';
    return FileSystemEntity.isFileSync(main) ? main : null;
  }
  return FileSystemEntity.isFileSync(candidate) ? candidate : null;
}

int _scan(List<String> args) {
  final dir = args.where((a) => !a.startsWith('-')).firstOrNull ?? 'e2e';
  final mainFile = File('$dir${Platform.pathSeparator}main.dart');
  if (!mainFile.existsSync()) {
    stderr
      ..writeln(
        'labwright scan: $dir/main.dart not found - the convention '
        'is a top-level main.dart every test module is plugged into',
      )
      ..writeln('run `labwright init` to generate the example e2e/ folder');
    return 64;
  }
  final reachable = <String>{};
  void visit(File file) {
    final path = file.absolute.uri.normalizePath().toFilePath();
    if (!reachable.add(path) || !file.existsSync()) return;
    for (final uri in localDirectiveUris(file.readAsStringSync())) {
      visit(File.fromUri(file.absolute.uri.resolve(uri)));
    }
  }

  visit(mainFile);

  final unplugged =
      Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !reachable.contains(f.absolute.uri.normalizePath().toFilePath()))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (unplugged.isEmpty) {
    stdout.writeln(
      'labwright scan: every .dart file under $dir/ is plugged '
      'into main.dart',
    );
    return 0;
  }
  stdout.writeln(
    'labwright scan: ${unplugged.length} file(s) not reachable '
    'from $dir/main.dart:',
  );
  for (final f in unplugged) {
    stdout.writeln('  ${f.path}');
  }
  stdout.writeln('plug them in (import + register call) or delete them.');
  return 1;
}

int _init(List<String> args) {
  final dir = args.where((a) => !a.startsWith('-')).firstOrNull ?? 'e2e';
  final main = File('$dir${Platform.pathSeparator}main.dart');
  final module = File('$dir${Platform.pathSeparator}power_rail_test.dart');
  for (final f in [main, module]) {
    if (f.existsSync()) {
      stderr.writeln(
        'labwright init: ${f.path} already exists - refusing '
        'to overwrite',
      );
      return 64;
    }
  }
  Directory(dir).createSync(recursive: true);
  main.writeAsStringSync('''
// The labwright suite entry point: ONE process, plain `dart run $dir/main.dart`
// (or `labwright run`). Bench setup is ordinary code at the top of main;
// every test module is plugged in by hand below — `labwright scan` lists
// any file you forgot.
import 'power_rail_test.dart' as power_rail;

Future<void> main() async {
  // Bench setup goes here — before any registration.
  power_rail.register();
}
''');
  module.writeAsStringSync('''
// One test module: expose a register() that main.dart plugs in. Tests are
// named bodies of ordinary code; package:test's expect and matchers work
// as-is, and any thrown exception fails the test.
import 'package:labwright/labwright.dart';

void register() {
  test('rail comes up', requirement: 'REQ-1', () async {
    log('replace this with real bench I/O');
    expect(3.3, inInclusiveRange(3.0, 3.6));
  });
}
''');
  stdout.writeln(
    'labwright init: wrote ${main.path} and ${module.path}\n'
    'run it with `labwright run` or `dart run ${main.path}`',
  );
  return 0;
}
