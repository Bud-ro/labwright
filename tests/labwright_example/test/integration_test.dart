import 'dart:convert';
import 'dart:io';

import 'package:labwright_example/labwright_example.dart';
import 'package:labwright_runner/labwright_runner.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// End-to-end across packages: example (engine + DAQ sim + traceability) ->
/// runner (JSON + TDMS) -> tdms reader. Guards cross-package regressions.
void main() {
  TdmsChannelData? findChannel(TdmsFile f, String name) {
    for (final g in f.groups) {
      final c = g.channel(name);
      if (c != null) return c;
    }
    return null;
  }

  test('run -> record.json + record.tdms -> read both back', () async {
    final tmp = await Directory.current.createTemp('lw_int_');
    addTearDown(() => tmp.delete(recursive: true));

    final rec = await psuTest(demoPsuDaq()).run(dutId: 'PSU-INT');
    final files = await writeRecord(rec, outDir: tmp.path);

    // --- JSON round-trip ---
    final json = jsonDecode(await files.json.readAsString()) as Map<String, Object?>;
    expect(json['dutId'], 'PSU-INT');
    expect(json['outcome'], 'pass');
    final phases = (json['phases'] as List).cast<Map<String, Object?>>();
    final railPhase = phases.firstWhere((p) => p['name'] == 'rail 3v3');
    final railMeas = (railPhase['measurements'] as List).cast<Map<String, Object?>>().single;
    expect(railMeas['name'], 'rail_3v3');
    // requirement refs survive serialization
    expect((railMeas['requirements'] as List).single, {'id': 'REQ-PWR-001', 'hash': 'a1'});

    // --- TDMS round-trip ---
    final tdms = TdmsReader.read(await files.tdms.readAsBytes());
    expect(tdms.properties['dutId'], 'PSU-INT');
    expect(tdms.properties['outcome'], 'pass');
    expect(findChannel(tdms, 'rail_3v3')!.data, [3.31]);
    expect(findChannel(tdms, 'rail_5v')!.data, [4.98]);
    expect(findChannel(tdms, 'rail_3v3')!.properties['units'], 'V');
    expect(findChannel(tdms, 'rail_3v3')!.properties['outcome'], 'pass');

    // --- JUnit report written alongside ---
    final junit = await files.junit.readAsString();
    expect(junit, contains('<testsuite name="psu-board" '));
    expect(junit, contains('<testcase name="rail 3v3"'));
  });

  test('a brownout propagates failure through both json and tdms', () async {
    final tmp = await Directory.current.createTemp('lw_int_');
    addTearDown(() => tmp.delete(recursive: true));

    final rec = await psuTest(demoPsuDaq(faultyRail5v: true)).run(dutId: 'PSU-BAD');
    final files = await writeRecord(rec, outDir: tmp.path);

    expect((jsonDecode(await files.json.readAsString()) as Map)['outcome'], 'fail');
    expect(TdmsReader.read(await files.tdms.readAsBytes()).properties['outcome'], 'fail');
  });
}
