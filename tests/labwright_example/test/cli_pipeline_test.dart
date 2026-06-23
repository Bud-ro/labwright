import 'dart:convert';
import 'dart:io';

import 'package:labwright_cli/labwright_cli.dart' as cli;
import 'package:labwright_example/labwright_example.dart';
import 'package:labwright_runner/labwright_runner.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// End-to-end guard for the documented sharded-CI pipeline (docs/ci-example.md):
/// two shards each produce a `record.tdms`, then the unified CLI merges them,
/// emits one aggregate JUnit report, and gates on requirement coverage — all
/// through the same commands the doc shows.
void main() {
  test('two shards -> tdms-merge + junit aggregate + trace gate', () async {
    final tmp = await Directory.current.createTemp('lw_pipe_');
    addTearDown(() => tmp.delete(recursive: true));

    // (1) Each shard runs the example test and writes its artifacts.
    final shardTdms = <String>[];
    for (final dut in ['PSU-A', 'PSU-B']) {
      final rec = await psuTest(demoPsuDaq()).run(dutId: dut);
      final files = await writeRecord(rec, outDir: '${tmp.path}/$dut');
      shardTdms.add(files.tdms.path);
    }

    // (2a) Merge both archives; channels from both shards survive (collision suffixed).
    final archive = '${tmp.path}/archive.tdms';
    expect(cli.run(['tdms-merge', archive, ...shardTdms], out: StringBuffer(), err: StringBuffer()), 0);
    final merged = TdmsReader.read(File(archive).readAsBytesSync());
    final channelNames = [for (final g in merged.groups) for (final c in g.channels) c.name];
    expect(channelNames.where((n) => n.startsWith('rail_3v3')).length, greaterThanOrEqualTo(2));

    // (2b) Aggregate JUnit: one <testsuites> wrapping a <testsuite> per shard.
    final junitOut = StringBuffer();
    expect(cli.run(['junit', ...shardTdms], out: junitOut, err: StringBuffer()), 0);
    final xml = junitOut.toString();
    expect(xml, contains('<testsuites'));
    expect('<testsuite '.allMatches(xml).length, 2);

    // (2c) Coverage gate against the example requirements (all covered, hashes match).
    final reqs = File('${tmp.path}/reqs.json')
      ..writeAsStringSync(jsonEncode([
        {'id': 'REQ-PWR-001', 'hash': 'a1'},
        {'id': 'REQ-PWR-002', 'hash': 'b2'},
        {'id': 'REQ-ID-001', 'hash': 'c3'},
      ]));
    expect(
      cli.run(['trace', '--min-coverage', '1.0', reqs.path, ...shardTdms], out: StringBuffer(), err: StringBuffer()),
      0,
    );

    // A stale hash makes the same gate fail (drift) — proves the gate has teeth.
    final stale = File('${tmp.path}/stale.json')
      ..writeAsStringSync(jsonEncode([
        {'id': 'REQ-PWR-001', 'hash': 'CHANGED'},
        {'id': 'REQ-PWR-002', 'hash': 'b2'},
        {'id': 'REQ-ID-001', 'hash': 'c3'},
      ]));
    expect(
      cli.run(['trace', '--min-coverage', '1.0', stale.path, ...shardTdms], out: StringBuffer(), err: StringBuffer()),
      1,
    );
  });
}
