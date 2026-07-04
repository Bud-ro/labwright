// Fixture: a failing run — expect() throws TestFailure (exceptions ARE how
// tests fail), the next test still runs (tests are independent), and the
// process exits non-zero. Registration is a plain synchronous burst from a
// sync main; execution starts after.
import 'package:labwright/labwright.dart';

void main() {
  test('trip threshold', requirement: 'REQ-9', () {
    expect(2.4, inInclusiveRange(1.9, 2.1), reason: 'trip current');
  });
  test('still reachable after trip', () {
    log('pinging DUT');
    expect(true, isTrue, reason: 'DUT responds');
  });
  test('teardown throws', () {
    throw StateError('relay stuck'); // non-TestFailure escape -> error status
  });
}
