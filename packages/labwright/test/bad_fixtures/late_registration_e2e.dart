// Fixture: the registration contract violated on purpose — an await between
// registrations lets the run start, so the late test() must throw a loud
// StateError instead of silently joining (sharding needs the full registry
// up front). The process must exit non-zero.
//
// The late registration triggers off the FIRST test's completion (flag +
// event-loop turns), not a wall-clock sleep: a fixed delay races the first
// test's machinery bring-up on a loaded machine, killing the process before
// its PASS line prints and flaking the assertion that the in-time test ran.
import 'package:labwright/labwright.dart';

var _ran = false;

Future<void> main() async {
  test('registered in time', () {
    _ran = true;
    expect(1, equals(1));
  });

  // WRONG: async work between registrations — the run starts here.
  while (!_ran) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  // The body finished; yield enough turns for its PASS line to be printed.
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }

  test('registered too late', () {
    expect(2, equals(2));
  });
}
