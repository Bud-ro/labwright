import 'dart:convert';
import 'dart:io';

import 'package:labwright_core/labwright_core.dart';

import 'junit.dart';
import 'record_tdms.dart';

/// Parsed CLI options for [runCli].
class RunOptions {
  const RunOptions({this.dutId = 'DUT', this.outDir = 'labwright-out', this.basename = 'record'});

  /// Identifier of the device under test for this run.
  final String dutId;

  /// Directory the artifacts are written to (created if needed).
  final String outDir;

  /// Filename stem for the artifacts (`<basename>.json/.tdms/.junit.xml`).
  final String basename;
}

/// Minimal flag parser: `--dut <id>`, `--out <dir>`, `--name <basename>`
/// (also accepts the `--flag=value` form).
RunOptions parseRunArgs(List<String> args) {
  var dut = 'DUT';
  var out = 'labwright-out';
  var name = 'record';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    final eq = a.indexOf('=');
    String take() {
      if (eq >= 0) return a.substring(eq + 1);
      if (i + 1 < args.length) {
        i++;
        return args[i];
      }
      return '';
    }

    if (a == '--dut' || a.startsWith('--dut=')) {
      dut = take();
    } else if (a == '--out' || a.startsWith('--out=')) {
      out = take();
    } else if (a == '--name' || a.startsWith('--name=')) {
      name = take();
    }
  }
  return RunOptions(dutId: dut, outDir: out, basename: name);
}

/// Writes [rec] to `<outDir>/<basename>.json`, `<outDir>/<basename>.tdms`, and
/// `<outDir>/<basename>.junit.xml` (a JUnit report CI test UIs ingest natively).
Future<({File json, File tdms, File junit})> writeRecord(
  TestRecord rec, {
  required String outDir,
  String basename = 'record',
}) async {
  final dir = await Directory(outDir).create(recursive: true);
  final json = rec.toJson();
  final jsonFile = File('${dir.path}/$basename.json');
  await jsonFile.writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');
  final tdmsFile = File('${dir.path}/$basename.tdms');
  await tdmsFile.writeAsBytes(recordToTdms(rec));
  final junitFile = File('${dir.path}/$basename.junit.xml');
  await junitFile.writeAsString(recordJsonToJUnit(json));
  return (json: jsonFile, tdms: tdmsFile, junit: junitFile);
}

/// CLI entrypoint: a test's `main` calls `runCli(myTest, args)`. Runs the test,
/// writes the record (JSON + TDMS), prints a summary, and returns a process exit
/// code (0 pass/skip, 1 fail, 2 error). [log] is injectable for testing.
Future<int> runCli(Test test, List<String> args, {void Function(String message)? log}) async {
  final void Function(String) emit = log ?? stdout.writeln;
  final opts = parseRunArgs(args);

  final rec = await test.run(dutId: opts.dutId);
  final files = await writeRecord(rec, outDir: opts.outDir, basename: opts.basename);

  emit('${test.name} [${rec.dutId}] -> ${rec.outcome.name.toUpperCase()} in ${rec.durationMs} ms');
  for (final p in rec.phases) {
    emit('  ${p.outcome.name.padRight(5)}  ${p.name}');
  }
  emit('wrote ${files.json.path}, ${files.tdms.path}, and ${files.junit.path}');

  return switch (rec.outcome) {
    Outcome.pass || Outcome.skip => 0,
    Outcome.fail => 1,
    Outcome.error => 2,
  };
}
