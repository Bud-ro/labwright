// Fixture: a green run — setup as plain code at the top of main, package:test
// assertions used as-is, a log line, and a skipTest (skips must NOT fail the
// process). No `_test.dart` suffix: E2E files are plain programs, never unit
// suites.
import 'package:labwright/labwright.dart';

/// Stands in for the bench singleton (pinMap etc.) — setup is just code.
var _railUp = false;

Future<void> main() async {
  _railUp = true; // setup runs before any test, no API needed

  await test('rail comes up', requirement: 'REQ-1', () async {
    log('applying power');
    expect(_railUp, isTrue);
    expect(3.3, inInclusiveRange(3.0, 3.6));
    await expectLater(Future.value(42), completion(equals(42)));
  });

  await test('ripple in limits', requirements: ['REQ-2', 'REQ-3'], () {
    expect(0.021, lessThan(0.05), reason: 'ripple under 50mV');
  });

  // TODO: port ThermalSweep.vi, then rename skipTest -> test to arm.
  await skipTest('thermal camera sweep', () async {
    throw UnimplementedError('VI call: ThermalSweep.vi');
  });
}
