import 'package:labwright/labwright.dart';

var _ok = true;

Future<void> main() async {
  test('toggles with the bench', () {
    expect(_ok, isTrue, reason: 'bench state decides the verdict');
  });

  button('break', () async => _ok = false);
  button('fix', () async => _ok = true);
}
