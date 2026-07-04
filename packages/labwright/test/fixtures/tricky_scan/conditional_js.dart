// The non-default branch of main.dart's conditional import — never loaded
// on the VM, but still part of the program: must count as plugged.
import 'package:labwright/labwright.dart';

void register() {
  test('conditional js branch', () {
    expect('js', isNotEmpty);
  });
}
