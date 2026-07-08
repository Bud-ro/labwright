// `labwright init` scaffolding and the CLI hot-restart supervisor.
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  test('init: generates the example suite; it runs green; refuses overwrite', () {
    const dir = '.init_tmp/e2e';
    final abs = Directory('$pkgRoot/.init_tmp');
    try {
      final created = cli(['init', dir]);
      expect(created.exitCode, 0, reason: created.stderr.toString());
      expect(File('$pkgRoot/$dir/main.dart').existsSync(), isTrue);
      expect(File('$pkgRoot/$dir/power_rail_test.dart').existsSync(), isTrue);

      final (exit, out, err) = runSuite('$dir/main.dart');
      expect(exit, 0, reason: '$out\n$err');
      expect(out, contains('PASS rail comes up'));

      expect(cli(['scan', dir]).exitCode, 0, reason: 'the generated suite passes its own plug-in lint');

      final again = cli(['init', dir]);
      expect(again.exitCode, 64, reason: 'must refuse to overwrite');
      expect(again.stderr.toString(), contains('already exists'));
    } finally {
      if (abs.existsSync()) abs.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('hot restart: the CLI supervisor respawns a fresh suite on the same port', () async {
    // A fixed free port: restart must rebind the SAME port so the page's
    // EventSource reconnects (probe-close race is acceptable in a test).
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final v = Viewer.attach(
      await Process.start(Platform.resolvedExecutable, [
        'run', 'bin/labwright.dart', 'run', 'test/fixtures/green_e2e.dart', //
        '--interactive', '--no-identity', '--port', '$port',
      ], workingDirectory: pkgRoot),
      fixedPort: port,
    );
    try {
      await v.ready();
      expect((await v.post('/restart')).$1, 202, reason: 'a supervised suite accepts the restart');

      // The supervisor notices the sentinel exit and a FRESH suite comes up on
      // the same port (fresh registration = the whole fix for edited bodies).
      await v.line('hot restart - starting a fresh suite process', timeout: const Duration(seconds: 30));
      await v.line('View results and re-run tests at', nth: 2);
      final state = await v.settle((s) => s['done'] == true, tolerateErrors: true);
      expect(state['supervised'], true);
      expect(state['tests'] as List, hasLength(3), reason: 'full fresh registration');
    } finally {
      await v.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
