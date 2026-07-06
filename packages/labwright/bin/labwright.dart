// The `labwright` CLI — thin sugar over the single-process test library.
//
//   labwright run [target] [--seed N|random] [--total-shards N --shard-index I]
//                 [--port N] [--no-viewer] [--report out.json]
//                 [--keep-open|--interactive]
//   labwright scan [dir]
//   labwright init [dir]
//
// run    Executes the suite: spawns exactly ONE `dart run` on the target
//        (default e2e/main.dart; a directory means its main.dart), mapping
//        each flag to the matching -Dlabwright.* define. Everything — tests,
//        viewer, report — happens inside that one process; `dart run
//        e2e/main.dart` directly is always equivalent (zero child
//        processes). SIGINT/SIGTERM forward to the child so nothing is
//        orphaned.
//   --seed N|random    Run-order seed (`random` mints one and prints it).
//   --total-shards N   With --shard-index I: run tests whose registration
//   --shard-index I    index is ≡ I (mod N) — dart test's convention.
//   --port N           Viewer port (default 1212; 0 = ephemeral).
//   --no-viewer        Disable the in-process viewer.
//   --no-identity      Skip the report's content-identity hashes (hot reload
//                      then conservatively re-runs everything).
//   --report out.json  Write the machine-readable run report.
//   --keep-open,       Keep the viewer serving after the run AND accept its
//   --interactive      control actions — re-run all/failed, run one, stop,
//                      buttons, open-in-editor, seed replay, hot reload (starts
//                      the VM service; re-runs only content-modified tests).
//                      Two names for one behavior; CI exits.
//
// scan   Lints the plug-in convention: lists .dart files under the dir
//        (default e2e/) that are NOT reachable from main.dart via local
//        imports — tests someone wrote but forgot to plug in. Exits 1 when
//        any are found, so CI can gate on it.
//
// init   Generates the example e2e/ folder (one super simple suite showing
//        the main.dart plug-in convention). Refuses to overwrite.
import 'dart:io';
import 'dart:math';

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
      // Bare `labwright path/...` reads as run.
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

// ── run ──────────────────────────────────────────────────────────────────────

Future<int> _run(List<String> args) async {
  final rest = [...args];
  String? target;
  final defines = <String>[];
  // Lingering (interactive/keep-open) enables the VM service so the viewer's
  // "hot reload" can reload edited sources in place.
  var linger = false;
  while (rest.isNotEmpty) {
    final arg = rest.removeAt(0);
    switch (arg) {
      case '--seed':
        final raw = rest.isEmpty ? '' : rest.removeAt(0);
        // `random` mints a fresh seed; it prints at the start of every test
        // for reproduction.
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

  // ONE child, sharing our stdio; signals forward so it is never orphaned.
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', if (linger) '--enable-vm-service=0', ...defines, path],
    mode: ProcessStartMode.inheritStdio,
  );
  final signals = [
    ProcessSignal.sigint.watch().listen((_) => process.kill(ProcessSignal.sigint)),
    ProcessSignal.sigterm.watch().listen((_) => process.kill()),
  ];
  final code = await process.exitCode;
  for (final s in signals) {
    await s.cancel();
  }
  return code;
}

/// Default target: `e2e/main.dart`. A directory means its `main.dart`; a
/// file is taken as-is.
String? _resolveTarget(String? target) {
  final candidate = target ?? 'e2e';
  if (FileSystemEntity.isDirectorySync(candidate)) {
    final main = '$candidate${Platform.pathSeparator}main.dart';
    return FileSystemEntity.isFileSync(main) ? main : null;
  }
  return FileSystemEntity.isFileSync(candidate) ? candidate : null;
}

// ── scan ─────────────────────────────────────────────────────────────────────

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
  // Everything reachable from main.dart, transitively — including THROUGH
  // files outside the scanned folder (a shared helper outside e2e/ that
  // imports a module back inside still plugs that module in).
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

// ── init ─────────────────────────────────────────────────────────────────────

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
