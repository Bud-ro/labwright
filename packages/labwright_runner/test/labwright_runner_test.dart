import 'dart:convert';
import 'dart:io';

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_runner/labwright_runner.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

Test _demo() => Test('rail check', [
      Phase('measure', (ctx) async {
        ctx.measure<num>('rail_V', units: 'V', validators: [Validators.approx(3.3, 0.1)]).value = 3.31;
        ctx.measure<num>('current_mA', units: 'mA').value = 12.0;
      }),
      Phase('serial', (ctx) async {
        ctx.measure<String>('serial', validators: [Validators.matches(RegExp(r'^SN'))]).value = 'SN123';
      }),
    ]);

void main() {
  test('maps a record to TDMS: file props, phase groups, measurement channels', () async {
    final rec = await _demo().run(dutId: 'DUT-7');
    final tdms = TdmsReader.read(recordToTdms(rec));

    expect(tdms.properties['dutId'], 'DUT-7');
    expect(tdms.properties['testName'], 'rail check');
    expect(tdms.properties['outcome'], 'pass');

    final g0 = tdms.groups.first;
    expect(g0.name, '00_measure');
    final rail = g0.channel('rail_V')!;
    expect(rail.data, [3.31]);
    expect(rail.properties['units'], 'V');
    expect(rail.properties['outcome'], 'pass');

    // String measurement: no numeric data, value stored as a property.
    final serial = tdms.group('01_serial')!.channel('serial')!;
    expect(serial.data, isEmpty);
    expect(serial.properties['value'], 'SN123');
  });

  test('requirement refs ride into the TDMS as channel + group properties', () async {
    final rec = await Test('traced', [
      Phase('rails', (ctx) async {
        ctx
            .measure<num>(
              'rail_3v3',
              units: 'V',
              validators: [Validators.approx(3.3, 0.1)],
              requirements: const [
                RequirementRef('REQ-PWR-001', hash: 'a1'),
                RequirementRef('REQ-PWR-002', hash: 'b2'),
              ],
            )
            .value = 3.31;
      }, requirements: const [RequirementRef('REQ-PWR-000', hash: 'z9')]),
    ]).run(dutId: 'DUT-T');
    final tdms = TdmsReader.read(recordToTdms(rec));

    final ch = tdms.group('00_rails')!.channel('rail_3v3')!;
    expect(ch.properties['requirements'], 'REQ-PWR-001@a1; REQ-PWR-002@b2');
    expect(tdms.group('00_rails')!.properties['requirements'], 'REQ-PWR-000@z9');
  });

  test('tdmsToRecordJson reconstructs a trace-ready record from TDMS alone', () async {
    final rec = await Test('traced', [
      Phase('rails', (ctx) async {
        ctx
            .measure<num>(
              'rail_3v3',
              units: 'V',
              validators: [Validators.approx(3.3, 0.1)],
              requirements: const [RequirementRef('REQ-PWR-001', hash: 'a1')],
            )
            .value = 3.31;
      }, requirements: const [RequirementRef('REQ-PWR-000', hash: 'z9')]),
    ]).run(dutId: 'DUT-T');

    // record -> TDMS bytes -> parse -> record-json, with no record.json involved.
    final back = tdmsToRecordJson(TdmsReader.read(recordToTdms(rec)));

    expect(back['dutId'], 'DUT-T');
    expect(back['testName'], 'traced');
    final phases = back['phases'] as List;
    final phase = phases.single as Map<String, Object?>;
    expect(phase['name'], 'rails'); // NN_ order prefix stripped
    expect(phase['outcome'], 'pass');
    expect(phase['requirements'], [
      {'id': 'REQ-PWR-000', 'hash': 'z9'},
    ]);
    final meas = (phase['measurements'] as List).single as Map<String, Object?>;
    expect(meas['name'], 'rail_3v3');
    expect(meas['requirements'], [
      {'id': 'REQ-PWR-001', 'hash': 'a1'},
    ]);
  });

  test('recordJsonToJUnit maps phases to testcases and failures', () async {
    final rec = await Test('rail check', [
      Phase('measure', (ctx) async {
        ctx.measure<num>('rail_V', units: 'V', validators: [Validators.atMost(1)]).value = 9.0; // fails
      }),
      Phase('serial', (ctx) async {
        ctx.measure<String>('sn').value = 'SN1'; // passes
      }),
    ]).run(dutId: 'DUT-7');

    final xml = recordJsonToJUnit(rec.toJson());
    expect(xml, startsWith('<?xml'));
    expect(xml, contains('<testsuite name="rail check" tests="2" failures="1" errors="0" skipped="0"'));
    expect(xml, contains('<testcase name="measure"'));
    expect(xml, contains('<failure message="failing measurements: rail_V"'));
    expect(xml, contains('<testcase name="serial"'));
    // Tags balance (well-formed enough for CI ingestion).
    expect('<testcase'.allMatches(xml).length, '</testcase>'.allMatches(xml).length);
  });

  test('recordJsonToJUnit escapes XML metacharacters', () {
    final xml = recordJsonToJUnit({
      'testName': 'a & b <x>',
      'phases': [
        {'name': 'p"1', 'outcome': 'error', 'error': 'boom <&>'},
      ],
    });
    expect(xml, contains('name="a &amp; b &lt;x&gt;"'));
    expect(xml, contains('name="p&quot;1"'));
    expect(xml, contains('<error message="boom &lt;&amp;&gt;">'));
  });

  test('recordsToJUnitSuites wraps one suite per record with aggregate counts', () {
    final a = {
      'testName': 'suiteA',
      'phases': [
        {'name': 'p1', 'outcome': 'pass'},
        {'name': 'p2', 'outcome': 'fail', 'measurements': <Object?>[]},
      ],
    };
    final b = {
      'testName': 'suiteB',
      'phases': [
        {'name': 'q1', 'outcome': 'error', 'error': 'boom'},
      ],
    };
    final xml = recordsToJUnitSuites([a, b]);
    expect(xml, contains('<testsuites tests="3" failures="1" errors="1" skipped="0">'));
    expect(xml, contains('<testsuite name="suiteA"'));
    expect(xml, contains('<testsuite name="suiteB"'));
    expect(xml, contains('</testsuites>'));
    expect('<testsuite '.allMatches(xml).length, 2);
  });

  test('recordJsonToJUnit works off a TDMS-reconstructed record', () async {
    final rec = await Test('t', [
      Phase('p', (ctx) async {
        ctx.measure<num>('v', validators: [Validators.inRange(0, 5)]).value = 3.0;
      }),
    ]).run(dutId: 'D');
    final reconstructed = tdmsToRecordJson(TdmsReader.read(recordToTdms(rec)));
    final xml = recordJsonToJUnit(reconstructed);
    expect(xml, contains('<testsuite name="t" tests="1" failures="0"'));
    expect(xml, contains('<testcase name="p"'));
  });

  test('runCli writes record.json + record.tdms and returns 0 on pass', () async {
    final tmp = await Directory.current.createTemp('lw_run_');
    addTearDown(() => tmp.delete(recursive: true));

    final logs = <String>[];
    final code = await runCli(_demo(), ['--dut', 'DUT-9', '--out', tmp.path], log: logs.add);
    expect(code, 0);

    final jsonFile = File('${tmp.path}/record.json');
    final tdmsFile = File('${tmp.path}/record.tdms');
    final junitFile = File('${tmp.path}/record.junit.xml');
    expect(jsonFile.existsSync(), isTrue);
    expect(tdmsFile.existsSync(), isTrue);
    expect(junitFile.existsSync(), isTrue);
    expect(await junitFile.readAsString(), contains('<testsuite'));
    expect(logs.any((l) => l.contains('record.junit.xml')), isTrue);

    final decoded = jsonDecode(await jsonFile.readAsString()) as Map<String, Object?>;
    expect(decoded['dutId'], 'DUT-9');
    expect(decoded['outcome'], 'pass');

    final tdms = TdmsReader.read(await tdmsFile.readAsBytes());
    expect(tdms.properties['dutId'], 'DUT-9');
    expect(logs.any((l) => l.contains('PASS')), isTrue);
  });

  test('exit code is 1 when the test fails', () async {
    final failing = Test('f', [
      Phase('p', (ctx) async {
        ctx.measure<num>('v', validators: [Validators.atMost(1)]).value = 9;
      }),
    ]);
    final tmp = await Directory.current.createTemp('lw_run_');
    addTearDown(() => tmp.delete(recursive: true));
    final code = await runCli(failing, ['--out', tmp.path], log: (_) {});
    expect(code, 1);
  });

  test('parseRunArgs handles space and = forms', () {
    expect(parseRunArgs(['--dut', 'A', '--out', 'o']).dutId, 'A');
    expect(parseRunArgs(['--dut=B']).dutId, 'B');
    expect(parseRunArgs([]).dutId, 'DUT');
  });
}
