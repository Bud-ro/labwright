import 'package:e2e_test/e2e_test.dart';
import 'package:test/test.dart';

import 'support/psu_board.dart';

void main() {
  // Each e2eTest drives a device end to end, like a testWidgets for hardware.
  // The device here is a simulated PSU board, so the suite runs in CI; on the
  // bench you'd hand `dut.use` a real plug and the bodies below stay identical.

  e2eTest(
    'a healthy board brings up every rail within tolerance',
    requirements: ['REQ-PWR-001', 'REQ-PWR-002'],
    (dut) async {
      final board = dut.use(PsuBoard());

      await dut.phase('3v3 rail', () async {
        final v = await board.railVoltage('3v3');
        dut.measure('rail_3v3', v, volts.within(3.3, 0.1),
            requirement: 'REQ-PWR-001');
      });

      await dut.phase('5v rail', () async {
        final v = await board.railVoltage('5v');
        dut.measure('rail_5v', v, volts.within(5.0, 0.25),
            requirement: 'REQ-PWR-002');
      });
    },
  );

  e2eTest(
    'a 5V brownout fails the run',
    expectedOutcome: Outcome.fail,
    (dut) async {
      final board = dut.use(PsuBoard(brownout5v: true));
      await dut.phase('5v rail', () async {
        final v = await board.railVoltage('5v');
        dut.measure('rail_5v', v, volts.within(5.0, 0.25));
      });
    },
  );

  test('a passing run round-trips through TDMS for the existing tooling',
      () async {
    final record = await runDevice('PSU-0001', (dut) async {
      final board = dut.use(PsuBoard());
      await dut.phase('3v3 rail', () async {
        dut.measure('rail_3v3', await board.railVoltage('3v3'),
            volts.within(3.3, 0.1));
      });
    });

    expect(record.outcome, Outcome.pass);

    final tdms = TdmsReader.read(record.toTdmsBytes());
    expect(tdms.properties['dutId'], 'PSU-0001');
    expect(tdms.properties['outcome'], 'pass');
    final rail = tdms.groups.single.channel('rail_3v3')!;
    expect(rail.data.single, closeTo(3.31, 1e-9));
    expect(rail.properties['units'], 'V');
  });
}
