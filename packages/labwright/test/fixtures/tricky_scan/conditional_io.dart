// The default branch of main.dart's conditional import. Both branches must
// count as plugged — either may be the one that loads.
import 'package:labwright/labwright.dart';

void register() {
  test('conditional io branch', () {
    expect('io', isNotEmpty);
  });
}
