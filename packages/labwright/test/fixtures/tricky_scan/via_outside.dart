// Plugged in through ../outside/bench_helpers.dart — reachable, not
// unplugged, even though nothing in THIS folder imports it directly.
import 'package:labwright/labwright.dart';

void register() {
  test('plugged via an outside helper', () {
    expect(1, equals(1));
  });
}
