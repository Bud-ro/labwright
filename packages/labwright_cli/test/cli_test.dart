import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_cli/labwright_cli.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('every command documented in usage is actually dispatched', () {
    // First token of each indented command line in the usage block.
    final commands = RegExp(r'^  ([a-z0-9][a-z0-9-]+)', multiLine: true)
        .allMatches(usage)
        .map((m) => m.group(1)!)
        .toSet();
    expect(commands, contains('tdms-inspect')); // sanity: extraction works
    expect(commands.length, greaterThanOrEqualTo(8));

    for (final cmd in commands) {
      final err = StringBuffer();
      // Invoking with no args should hit the command's own handler (usage/missing
      // file/etc.), never the dispatcher's "unknown command" fallthrough.
      run([cmd], out: StringBuffer(), err: err);
      expect(err.toString(), isNot(contains('unknown command')), reason: '"$cmd" is in usage but not dispatched');
    }

    // Exit codes are exposed as named constants, not magic numbers.
    expect(ExitCodes.usage, 64);
    expect(ExitCodes.ok, 0);
  });

  test('no args prints usage and returns 64', () {
    final out = StringBuffer();
    final err = StringBuffer();
    expect(run([], out: out, err: err), 64);
    expect(err.toString(), contains('usage: labwright'));
  });

  test('--help prints usage to stdout and returns 0', () {
    final out = StringBuffer();
    expect(run(['--help'], out: out, err: StringBuffer()), 0);
    expect(out.toString(), contains('usage: labwright'));
  });

  test('--version prints the version and returns 0', () {
    final out = StringBuffer();
    expect(run(['--version'], out: out, err: StringBuffer()), 0);
    expect(out.toString(), contains('labwright 0.0.1'));
  });

  test('unknown command returns 64 with a hint', () {
    final out = StringBuffer();
    final err = StringBuffer();
    expect(run(['bogus'], out: out, err: err), 64);
    expect(err.toString(), contains('unknown command'));
  });

  test('missing file returns 66', () {
    final out = StringBuffer();
    final err = StringBuffer();
    expect(run(['tdms-inspect', '/no/such/file.tdms'], out: out, err: err), 66);
  });

  test('tdms-inspect dispatches to the TDMS reader', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    final f = File('${tmp.path}/x.tdms')
      ..writeAsBytesSync(
        (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0])])).toBytes(),
      );

    final out = StringBuffer();
    final err = StringBuffer();
    expect(run(['tdms-inspect', f.path], out: out, err: err), 0);
    expect(out.toString(), contains('group "M"'));
    expect(out.toString(), contains('channel "v"'));
  });

  test('vi commands report bad content as exit 65', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    // a valid TDMS file is not a valid VI -> ViFormatException -> 65
    final f = File('${tmp.path}/x.tdms')
      ..writeAsBytesSync((TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [1.0])])).toBytes());
    final out = StringBuffer();
    final err = StringBuffer();
    expect(run(['vi-summary', f.path], out: out, err: err), 65);
    expect(err.toString(), contains('ViFormatException'));
  });

  test('trace returns 1 when a requirement is uncovered', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/reqs.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"}]');
    File('${tmp.path}/rec.json').writeAsStringSync('{"phases":[]}');

    final out = StringBuffer();
    final err = StringBuffer();
    expect(run(['trace', '${tmp.path}/reqs.json', '${tmp.path}/rec.json'], out: out, err: err), 1);
    expect(out.toString(), contains('UNCOVERED'));
  });

  test('trace reads requirement coverage directly from a self-describing .tdms', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/reqs.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"}]');
    // A TDMS shaped like recordToTdms output: group per phase, channel per
    // measurement, requirement refs embedded as properties.
    final bytes = (TdmsWriter()
          ..writeSegment(
            [
              TdmsChannel(
                group: '00_rails',
                name: 'v',
                data: const [3.3],
                properties: const {'outcome': 'pass', 'requirements': 'REQ-1@h1'},
              ),
            ],
            groupProperties: const {
              '00_rails': {'outcome': 'pass'},
            },
          ))
        .toBytes();
    File('${tmp.path}/rec.tdms').writeAsBytesSync(bytes);

    final out = StringBuffer();
    final err = StringBuffer();
    // REQ-1 is covered (pass) with a matching hash -> matrix ok -> exit 0.
    expect(run(['trace', '${tmp.path}/reqs.json', '${tmp.path}/rec.tdms'], out: out, err: err), 0);
    expect(out.toString(), contains('REQ-1'));
    expect(out.toString(), isNot(contains('UNCOVERED')));
  });

  test('trace flags hash drift when a .tdms pins a stale requirement hash', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/reqs.json').writeAsStringSync('[{"id":"REQ-1","hash":"NEW"}]');
    final bytes = (TdmsWriter()
          ..writeSegment([
            TdmsChannel(
              group: '00_rails',
              name: 'v',
              data: const [3.3],
              properties: const {'outcome': 'pass', 'requirements': 'REQ-1@OLD'},
            ),
          ]))
        .toBytes();
    File('${tmp.path}/rec.tdms').writeAsBytesSync(bytes);

    final out = StringBuffer();
    expect(run(['trace', '${tmp.path}/reqs.json', '${tmp.path}/rec.tdms'], out: out, err: StringBuffer()), 1);
    expect(out.toString(), contains('DRIFT'));
  });

  test('trace --json emits a machine-readable matrix', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/reqs.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"}]');
    File('${tmp.path}/rec.json').writeAsStringSync(
      '{"testName":"t","phases":[{"name":"p","outcome":"pass",'
      '"measurements":[{"name":"v","outcome":"pass","requirements":[{"id":"REQ-1","hash":"h1"}]}]}]}',
    );

    final out = StringBuffer();
    expect(run(['trace', '--json', '${tmp.path}/reqs.json', '${tmp.path}/rec.json'], out: out, err: StringBuffer()), 0);
    final decoded = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(decoded['ok'], isTrue);
    expect(decoded['total'], 1);
    final req = (decoded['requirements'] as List).single as Map<String, Object?>;
    expect(req['id'], 'REQ-1');
    expect(req['covered'], isTrue);
    expect(req['outcome'], 'pass');
  });

  test('trace --min-coverage gates the exit code on the threshold', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    // 3 requirements, only 2 covered (2/3 ≈ 0.667).
    File('${tmp.path}/reqs.json')
        .writeAsStringSync('[{"id":"REQ-1","hash":"h1"},{"id":"REQ-2","hash":"h2"},{"id":"REQ-3","hash":"h3"}]');
    File('${tmp.path}/rec.json').writeAsStringSync(
      '{"phases":[{"name":"p","outcome":"pass","measurements":['
      '{"name":"a","outcome":"pass","requirements":[{"id":"REQ-1","hash":"h1"}]},'
      '{"name":"b","outcome":"pass","requirements":[{"id":"REQ-2","hash":"h2"}]}]}]}',
    );
    final reqs = '${tmp.path}/reqs.json';
    final rec = '${tmp.path}/rec.json';

    // Default (full coverage) -> REQ-3 uncovered -> fail.
    expect(run(['trace', reqs, rec], out: StringBuffer(), err: StringBuffer()), 1);
    // Threshold 0.6 -> 2/3 passes.
    expect(run(['trace', '--min-coverage', '0.6', reqs, rec], out: StringBuffer(), err: StringBuffer()), 0);
    // Threshold 0.9 -> still fails.
    expect(run(['trace', '--min-coverage=0.9', reqs, rec], out: StringBuffer(), err: StringBuffer()), 1);

    // The JSON `ok` reflects the threshold too.
    final out = StringBuffer();
    expect(run(['trace', '--json', '--min-coverage', '0.6', reqs, rec], out: out, err: StringBuffer()), 0);
    expect((jsonDecode(out.toString()) as Map<String, Object?>)['ok'], isTrue);
  });

  test('trace rejects a malformed --min-coverage with exit 64', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/reqs.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"}]');
    File('${tmp.path}/rec.json').writeAsStringSync('{"phases":[]}');
    final err = StringBuffer();
    expect(
      run(['trace', '--min-coverage', 'banana', '${tmp.path}/reqs.json', '${tmp.path}/rec.json'],
          out: StringBuffer(), err: err),
      64,
    );
    expect(err.toString(), contains('invalid --min-coverage'));
    // Out of range is also rejected.
    expect(
      run(['trace', '--min-coverage=1.5', '${tmp.path}/reqs.json', '${tmp.path}/rec.json'],
          out: StringBuffer(), err: StringBuffer()),
      64,
    );
  });

  test('tdms-diff returns 0 for identical files and 1 when they differ', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    Uint8List bytes(List<double> d) =>
        (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: d)])).toBytes();
    File('${tmp.path}/a.tdms').writeAsBytesSync(bytes(const [1.0, 2.0, 3.0]));
    File('${tmp.path}/b.tdms').writeAsBytesSync(bytes(const [1.0, 2.0, 3.0]));
    File('${tmp.path}/c.tdms').writeAsBytesSync(bytes(const [1.0, 9.0, 3.0]));
    final a = '${tmp.path}/a.tdms';
    final b = '${tmp.path}/b.tdms';
    final c = '${tmp.path}/c.tdms';

    expect(run(['tdms-diff', a, b], out: StringBuffer(), err: StringBuffer()), 0);

    final out = StringBuffer();
    expect(run(['tdms-diff', a, c], out: out, err: StringBuffer()), 1);
    expect(out.toString(), contains('valueDiff'));

    // --tol absorbs the difference back to "identical".
    expect(run(['tdms-diff', '--tol', '10', a, c], out: StringBuffer(), err: StringBuffer()), 0);

    // --json emits a parseable summary.
    final j = StringBuffer();
    expect(run(['tdms-diff', '--json', a, c], out: j, err: StringBuffer()), 1);
    expect((jsonDecode(j.toString()) as Map<String, Object?>)['identical'], isFalse);
  });

  test('tdms-diff rejects a malformed --tol with exit 64', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    final bytes = (TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [1.0])])).toBytes();
    File('${tmp.path}/a.tdms').writeAsBytesSync(bytes);
    File('${tmp.path}/b.tdms').writeAsBytesSync(bytes);
    final err = StringBuffer();
    expect(
      run(['tdms-diff', '--tol', 'xyz', '${tmp.path}/a.tdms', '${tmp.path}/b.tdms'], out: StringBuffer(), err: err),
      64,
    );
    expect(err.toString(), contains('invalid --tol'));
  });

  test('tdms-merge unions two files and suffixes collisions', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    Uint8List bytes(String group, String name, List<double> d) =>
        (TdmsWriter()..writeSegment([TdmsChannel(group: group, name: name, data: d)])).toBytes();
    File('${tmp.path}/a.tdms').writeAsBytesSync(bytes('G', 'v', const [1.0]));
    File('${tmp.path}/b.tdms').writeAsBytesSync(bytes('G', 'v', const [2.0])); // collision
    final outPath = '${tmp.path}/out.tdms';

    final out = StringBuffer();
    expect(
      run(['tdms-merge', outPath, '${tmp.path}/a.tdms', '${tmp.path}/b.tdms'], out: out, err: StringBuffer()),
      0,
    );
    expect(out.toString(), contains('2 files merged'));

    final merged = TdmsReader.read(File(outPath).readAsBytesSync());
    final g = merged.group('G')!;
    expect(g.channel('v')!.data, [1.0]);
    expect(g.channel('v#2')!.data, [2.0]); // collision suffixed, not lost
  });

  test('tdms-merge needs an output plus at least two inputs (usage 64)', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    final f = '${tmp.path}/a.tdms';
    File(f).writeAsBytesSync((TdmsWriter()..writeSegment([TdmsChannel(group: 'G', name: 'v', data: const [1.0])])).toBytes());
    final err = StringBuffer();
    expect(run(['tdms-merge', '${tmp.path}/out.tdms', f], out: StringBuffer(), err: err), 64);
    expect(err.toString(), contains('usage: labwright tdms-merge'));
  });

  test('junit emits XML from a record.json and from a .tdms', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/rec.json').writeAsStringSync(
      '{"testName":"t","phases":[{"name":"p","outcome":"fail","measurements":'
      '[{"name":"v","outcome":"fail","value":9}]}]}',
    );
    final jsonOut = StringBuffer();
    expect(run(['junit', '${tmp.path}/rec.json'], out: jsonOut, err: StringBuffer()), 0);
    expect(jsonOut.toString(), contains('<testsuite name="t" tests="1" failures="1"'));
    expect(jsonOut.toString(), contains('<failure'));

    // Same command off a self-describing .tdms.
    final bytes = (TdmsWriter()
          ..writeSegment(
            [TdmsChannel(group: '00_p', name: 'v', data: const [3.0], properties: const {'outcome': 'pass'})],
            groupProperties: const {
              '00_p': {'outcome': 'pass'},
            },
            fileProperties: const {'testName': 'fromTdms'},
          ))
        .toBytes();
    File('${tmp.path}/rec.tdms').writeAsBytesSync(bytes);
    final tdmsOut = StringBuffer();
    expect(run(['junit', '${tmp.path}/rec.tdms'], out: tdmsOut, err: StringBuffer()), 0);
    expect(tdmsOut.toString(), contains('<testsuite name="fromTdms"'));
  });

  test('reqs-lint passes a clean file and flags a dirty one', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/clean.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"},{"id":"REQ-2","hash":"h2"}]');
    File('${tmp.path}/dirty.json').writeAsStringSync('[{"id":"REQ-1","hash":"h1"},{"id":"REQ-1","hash":""}]');

    final cleanOut = StringBuffer();
    expect(run(['reqs-lint', '${tmp.path}/clean.json'], out: cleanOut, err: StringBuffer()), 0);
    expect(cleanOut.toString(), contains('OK'));

    final dirtyOut = StringBuffer();
    expect(run(['reqs-lint', '${tmp.path}/dirty.json'], out: dirtyOut, err: StringBuffer()), 1);
    expect(dirtyOut.toString(), contains('duplicate id "REQ-1"'));
    expect(dirtyOut.toString(), contains('missing/empty'));
  });

  test('reqs-lint reports bad JSON (65) and missing files (66)', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/bad.json').writeAsStringSync('{not json');
    expect(run(['reqs-lint', '${tmp.path}/bad.json'], out: StringBuffer(), err: StringBuffer()), 65);
    expect(run(['reqs-lint', '${tmp.path}/nope.json'], out: StringBuffer(), err: StringBuffer()), 66);
  });

  test('junit aggregates multiple records into one <testsuites>', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/a.json').writeAsStringSync('{"testName":"A","phases":[{"name":"p","outcome":"pass"}]}');
    File('${tmp.path}/b.json').writeAsStringSync('{"testName":"B","phases":[{"name":"q","outcome":"fail"}]}');
    final out = StringBuffer();
    expect(run(['junit', '${tmp.path}/a.json', '${tmp.path}/b.json'], out: out, err: StringBuffer()), 0);
    final xml = out.toString();
    expect(xml, contains('<testsuites tests="2" failures="1"'));
    expect(xml, contains('<testsuite name="A"'));
    expect(xml, contains('<testsuite name="B"'));
  });

  test('junit without a file is a usage error (64)', () {
    final err = StringBuffer();
    expect(run(['junit'], out: StringBuffer(), err: err), 64);
    expect(err.toString(), contains('usage: labwright junit'));
  });

  test('csv2tdms imports a CSV file into a TDMS file', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/in.csv').writeAsStringSync('volts,amps\n3.3,0.5\n3.31,0.6\n');
    expect(run(['csv2tdms', '${tmp.path}/in.csv', '${tmp.path}/out.tdms'], out: StringBuffer(), err: StringBuffer()), 0);
    final f = TdmsReader.read(File('${tmp.path}/out.tdms').readAsBytesSync());
    expect(f.group('Imported')!.channel('volts')!.data, [3.3, 3.31]);
  });

  test('tdms-csv emits CSV for a TDMS file', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/x.tdms')
        .writeAsBytesSync((TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0])])).toBytes());
    final out = StringBuffer();
    expect(run(['tdms-csv', '${tmp.path}/x.tdms'], out: out, err: StringBuffer()), 0);
    expect(out.toString(), contains('M/v'));
    expect(out.toString(), contains('1.0'));
  });

  test('tdms-summary emits valid JSON', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/x.tdms')
        .writeAsBytesSync((TdmsWriter()..writeSegment([TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0])])).toBytes());
    final out = StringBuffer();
    expect(run(['tdms-summary', '${tmp.path}/x.tdms'], out: out, err: StringBuffer()), 0);
    expect((jsonDecode(out.toString()) as Map<String, Object?>)['groups'], isA<List<Object?>>());
  });

  test('CLI round-trip: csv2tdms then tdms-inspect shows the channel', () async {
    final tmp = await Directory.current.createTemp('lw_cli_');
    addTearDown(() => tmp.delete(recursive: true));
    File('${tmp.path}/in.csv').writeAsStringSync('rail\n3.3\n3.31\n');
    expect(run(['csv2tdms', '${tmp.path}/in.csv', '${tmp.path}/out.tdms'], out: StringBuffer(), err: StringBuffer()), 0);
    final out = StringBuffer();
    expect(run(['tdms-inspect', '${tmp.path}/out.tdms'], out: out, err: StringBuffer()), 0);
    expect(out.toString(), contains('channel "rail"'));
  });
}
