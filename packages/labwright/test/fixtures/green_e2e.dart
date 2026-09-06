import 'package:labwright/labwright.dart';

var _railUp = false;

Future<void> main() async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  _railUp = true;
  context('dut.serial', 'SIM-001');

  test('rail comes up', requirement: 'REQ-1', () async {
    log('applying power');
    expect(_railUp, isTrue, reason: 'setup at the top of main ran before any body');
    expect(3.3, inInclusiveRange(3.0, 3.6));
    await expectLater(Future.value(42), completion(equals(42)));
  });

  test('ripple in limits', requirements: ['REQ-2', 'REQ-3'], () {
    expect(0.021, lessThan(0.05), reason: 'ripple under 50mV');
  });

  skipTest('thermal camera sweep', () async {
    throw UnimplementedError('VI call: ThermalSweep.vi');
  });

  button('reset rig', () async {
    _railUp = false;
    log('rig reset');
  });
}
