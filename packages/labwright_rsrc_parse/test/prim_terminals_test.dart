import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  test('prim icon names round-trip through primIconName and parsePrimIconName', () {
    final keys = [1050, 0, -0x44, -0x3a, classVariantIconKey(0x44, 3), classVariantIconKey(0x3a, 0)];
    for (final key in keys) {
      expect(parsePrimIconName(primIconName(key)), key, reason: primIconName(key));
    }
    expect(primIconName(1050), 'prim1050');
    expect(primIconName(-0x44), 'class68');
    expect(primIconName(classVariantIconKey(0x44, 3)), 'class68_t3');
    expect(parsePrimIconName('icon7'), isNull);
    expect(parsePrimIconName('prim'), isNull);
  });

  test('measured prim terminal offsets only fill axes the census leaves open or agree with it', () {
    for (final entry in kBdPrimTerminalMeasured.entries) {
      final census = kBdPrimTerminalCensus[entry.key];
      if (census == null) continue;
      for (final (measured, seen) in [(entry.value.dx, census.dx), (entry.value.dy, census.dy)]) {
        if (seen != null && measured != null) expect(measured, seen, reason: '${entry.key}');
      }
    }
  });
}
