// Deliberately not imported by main.dart — the test someone wrote and
// forgot to plug in. `labwright scan` exits non-zero naming this file.
import 'package:labwright/labwright.dart';

void register() {
  test('forgotten', () {
    expect(true, isTrue);
  });
}
