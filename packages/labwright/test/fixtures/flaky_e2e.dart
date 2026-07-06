// Fixture for the run-to-run diff: one test whose verdict flips with bench
// state that two operator buttons toggle. Re-running after 'break' turns it
// failed (newFail); after 'fix', passed again (newPass, and flaky once it has
// flipped twice). Interactive/viewer only — a plain pass just sees it green.
import 'package:labwright/labwright.dart';

var _ok = true;

Future<void> main() async {
  test('toggles with the bench', () {
    expect(_ok, isTrue, reason: 'bench state decides the verdict');
  });

  button('break', () async => _ok = false);
  button('fix', () async => _ok = true);
}
