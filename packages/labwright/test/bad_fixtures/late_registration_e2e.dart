import 'package:labwright/labwright.dart';

var _ran = false;

Future<void> main() async {
  test('registered in time', () {
    _ran = true;
    expect(1, equals(1));
  });

  while (!_ran) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }

  test('registered too late', () {
    expect(2, equals(2));
  });
}
