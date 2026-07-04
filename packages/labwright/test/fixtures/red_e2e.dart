// Fixture: a failing run — a false check fails the step but execution
// continues (TestStand continue-on-fail), and the process exits non-zero.
import 'package:labwright/labwright.dart';

Future<void> main() async {
  await sequence('Overcurrent', (s) async {
    await s.step('Trip threshold', requirement: 'REQ-9', (ctx) async {
      ctx.check(false, 'trip current 2.4A within [1.9, 2.1]');
      ctx.check(true, 'recovery time under 10ms');
    });
    await s.step('Still reachable after trip', (ctx) async {
      ctx.check(true, 'DUT responds');
    });
  });
}
