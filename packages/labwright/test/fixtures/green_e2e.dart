// Fixture: a green run — passing checks, a log line, and one pending step
// (pending must NOT fail the process). No `_test.dart` suffix: E2E files are
// plain programs, never unit-test suites.
import 'package:labwright/labwright.dart';

Future<void> main() async {
  await sequence('PowerRail', requirements: ['REQ-SEQ-1'], (s) async {
    await s.step('Rail comes up', requirement: 'REQ-1', (ctx) async {
      ctx.log('applying power');
      ctx.check(3.3 > 3.0, '3.3V rail above 3.0V');
    });
    await s.step('Ripple in limits', requirements: ['REQ-2', 'REQ-3'],
        (ctx) async {
      ctx.check(true, 'ripple under 50mV');
    });
    await s.step('Thermal camera sweep', (ctx) async {
      ctx.pending('VI call: ThermalSweep.vi');
    });
  });
}
