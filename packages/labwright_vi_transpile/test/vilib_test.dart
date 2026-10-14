import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

void main() {
  test('every vilib VI is keyed by its lower-cased file name and names the function it holds', () {
    for (final MapEntry(:key, value: vi) in lvVilibVis.entries) {
      expect(key, vi.fileName.toLowerCase());
      expect(vi.function.toString(), contains("'${vi.dartName}'"), reason: vi.fileName);
      expect(vi.terminals.map((t) => t.pane), everyElement(lessThan(vi.paneWidth)));
      expect(vi.terminals.map((t) => t.pane).toSet(), hasLength(vi.terminals.length));
      expect(vi.terminals.map((t) => t.wireType.isMapped), everyElement(isTrue), reason: vi.fileName);
    }
  });

  test('each pane terminal: its index, control name, direction and Dart type', () {
    String row(LvVilibTerminal t) => '${t.pane} ${t.name} ${t.isIndicator ? 'out' : 'in'} ${t.wireType.dartType}';
    const rows = {
      'Space Constant.vi': ['0 space out String'],
      'Application Directory.vi': ['0 path out LvPath'],
      'Trim Whitespace.vi': ['0 string in String', '1 location in int', '2 trimmed string out String'],
      'Color to RGB.vi': ['0 color in int', '2 red out int', '3 green out int', '4 blue out int'],
      'Error Cluster From Error Code.vi': [
        '0 error out out LvError',
        '5 show call chain? in bool',
        '6 error in in LvError',
        '8 message in String',
        '9 error code in int',
      ],
    };
    expect({for (final vi in lvVilibVis.values) vi.fileName: vi.terminals.map(row).toList()}, rows);
    expect(lvColorToRgbVi.paneWidth, 5);
    expect(lvErrorClusterFromErrorCodeVi.paneWidth, 10);
  });

  test('the one enum terminal passes as the runtime enum, whose values are its ring', () {
    final enums = lvVilibVis.values.expand((vi) => vi.terminals).where((t) => t.runtimeEnum != null).toList();
    expect(enums.map((t) => (t.pane, t.name, t.runtimeEnum)), [(1, 'location', 'LvTrimLocation')]);
    expect(LvTrimLocation.values.map((v) => v.name), ['both', 'start', 'end']);
  });
}
