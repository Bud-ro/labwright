import 'dart:io';

import 'package:test/test.dart';

import 'export_snapshot.dart';

void main() {
  for (final project in ['seq-corpus/rosetta/OutputVoltage', 'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo']) {
    test('the $project snapshot runs green', () {
      final run = Process.runSync(Platform.resolvedExecutable, [
        'run',
        '-Dlabwright.viewer=false',
        '$exportSnapshotPath/$project/main.dart',
      ]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
