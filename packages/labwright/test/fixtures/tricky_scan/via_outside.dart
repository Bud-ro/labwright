import 'package:labwright/labwright.dart';

void register() {
  test('plugged via an outside helper', () {
    expect(1, equals(1));
  });
}
