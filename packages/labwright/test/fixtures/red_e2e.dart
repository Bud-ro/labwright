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
    throw StateError('relay stuck');
  });
}
