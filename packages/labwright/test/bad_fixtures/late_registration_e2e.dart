// Fixture: the registration contract violated on purpose — an await between
// registrations lets the run start, so the late test() must throw a loud
// StateError instead of silently joining (sharding needs the full registry
// up front). The process must exit non-zero.
import 'package:labwright/labwright.dart';

Future<void> main() async {
  test('registered in time', () {
    expect(1, equals(1));
  });

  // WRONG: async work between registrations — the run starts here.
  await Future<void>.delayed(const Duration(milliseconds: 50));

  test('registered too late', () {
    expect(2, equals(2));
  });
}
