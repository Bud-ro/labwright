// Hot reload over the VM service: edited sources re-run in place, and content
// hashes confine the re-run to modified tests. Each test writes a throwaway
// suite inside the package (so package: URIs resolve) and edits it live.
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

const _t2 = Timeout(Duration(minutes: 2));

void main() {
  test('hot reload: reloads edited sources and re-runs in place', () async {
    final dir = Directory('$pkgRoot/.hot_tmp')..createSync(recursive: true);
    String src(String marker) =>
        "import 'package:labwright/labwright.dart';\n"
        "String marker() => '$marker';\n"
        "void main() {\n  test('marker', () async { log(marker()); });\n}\n";
    final suite = File('${dir.path}/suite.dart')..writeAsStringSync(src('MARKER_A'));
    Viewer? v;
    try {
      v = await Viewer.start(
        '.hot_tmp/suite.dart',
        defines: ['-Dlabwright.interactive=true', '-Dlabwright.identity=false'],
        vmService: true,
      );
      List<Object?>? logsIn(Map<String, Object?> s) =>
          (testsOf(s).single['logs'] as List?)?.map((l) => (l as Map)['m']).toList();
      expect(logsIn(await v.settle((s) => s['busy'] == false)), ['MARKER_A']);

      suite.writeAsStringSync(src('MARKER_B'));
      final (code, _) = await v.post('/reload');
      expect(code, 202, reason: 'reload accepted (VM service is on)');
      final after = await v.settle((s) => s['busy'] == false && (logsIn(s)?.contains('MARKER_B') ?? false));
      expect(logsIn(after), ['MARKER_B'], reason: 'the reloaded code ran on re-run');
    } finally {
      await v?.close();
      dir.deleteSync(recursive: true);
    }
  }, timeout: _t2);

  test('hot reload re-runs only modified tests; hashes factor test bodies out of setup', () async {
    final dir = Directory('$pkgRoot/.hot_tmp')..createSync(recursive: true);
    String src({required String alpha, required String helper}) =>
        "import 'package:labwright/labwright.dart';\n"
        "String helper() => '$helper';\n"
        'void main() {\n'
        "  test('alpha', () async { log('$alpha'); });\n"
        "  test('beta', () async { log(helper()); });\n"
        '}\n';
    final suite = File('${dir.path}/suite.dart')..writeAsStringSync(src(alpha: 'A1', helper: 'H1'));
    Viewer? v;
    try {
      final viewer = v = await Viewer.start(
        '.hot_tmp/suite.dart',
        defines: ['-Dlabwright.interactive=true', '-Dlabwright.seed=0'],
        vmService: true,
      );
      Future<int> reload() async {
        final (code, body) = await viewer.post('/reload');
        expect(code, 202);
        await viewer.settle((s) => s['busy'] == false);
        return (body!['modified'] as num).toInt();
      }

      final r1 = await viewer.getJson('/report.json');

      // Edit ONLY alpha's body: alpha is modified, beta and the SETUP are not.
      suite.writeAsStringSync(src(alpha: 'A2', helper: 'H1'));
      expect(await reload(), 1, reason: 'exactly the edited test counts as modified');
      await viewer.line('[Labwright]: hot reload - 1 modified test(s)', timeout: const Duration(seconds: 10));
      final r2 = await viewer.getJson('/report.json');
      expect(testIn(r2, 'alpha')['hash'], isNot(testIn(r1, 'alpha')['hash']));
      expect(testIn(r2, 'beta')['hash'], testIn(r1, 'beta')['hash']);
      expect(r2['setupHash'], r1['setupHash'], reason: 'test bodies are factored OUT of the setup hash');
      expect(testIn(r2, 'beta')['finishedAt'], testIn(r1, 'beta')['finishedAt'], reason: 'unmodified: not re-run');
      expect(testIn(r2, 'alpha')['finishedAt'], isNot(testIn(r1, 'alpha')['finishedAt']), reason: 'modified: re-ran');

      // Edit the shared helper (outside any test body): setup changed -> all.
      suite.writeAsStringSync(src(alpha: 'A2', helper: 'H2'));
      expect(await reload(), 2, reason: 'a setup change conservatively marks every test modified');
      expect((await viewer.getJson('/report.json'))['setupHash'], isNot(r2['setupHash']));

      expect(await reload(), 0, reason: 'an unchanged suite re-runs nothing');
    } finally {
      await v?.close();
      dir.deleteSync(recursive: true);
    }
  }, timeout: _t2);
}
