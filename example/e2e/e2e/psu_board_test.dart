// The example bench module: `register()` is called from e2e/main.dart and
// only REGISTERS — bodies run after main returns, one at a time. The device
// is a simulated PSU board so the suite runs anywhere; on a real bench you
// hand `dut.use` a driver that implements Plug and the bodies stay
// identical.
import 'package:e2e_test/e2e_test.dart';
import 'package:e2e_test/psu_board.dart';
import 'package:labwright/labwright.dart';

void register() {
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

  // labwright has no expected-failure tier (an exception IS a failure), so
  // proving the fault is CAUGHT is a normal passing test: the sagged rail
  // must read OUTSIDE its limit.
  test('a 5V brownout is caught by the rail limit', () async {
    final board = PsuBoard(brownout5v: true);
    const nominal = 5.0;
    final limit = volts.within(nominal, 0.25);
    final v = await board.railVoltage('5v');
    log('brownout 5v rail reads $v V against $limit');
    expect(limit.accepts(v), isFalse,
        reason: 'a browned-out rail must fall outside $limit');
  });

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
