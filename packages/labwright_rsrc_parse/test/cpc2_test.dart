import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

ViSection sec(String tag, List<int> bytes) =>
    ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes));

void main() {
  test('cpc2Description decodes a u32-length-prefixed ASCII description', () {
    const text = 'Calls SetETS';
    final cpc2 = <int>[0, 0, 0, text.length, ...text.codeUnits];
    expect(cpc2Description([sec('CPC2', cpc2)]), 'Calls SetETS');
  });

  test('cpc2Description returns null for a non-description CPC2 variant', () {
    // a compiled-cache variant (binary, no clean length-prefixed ASCII)
    final cpc2 = <int>[0xff, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x01];
    expect(cpc2Description([sec('CPC2', cpc2)]), isNull);
    expect(cpc2Description([sec('vers', [1, 2, 3])]), isNull); // no CPC2
  });

  test('cpc2Description is total over arbitrary bytes', () {
    final rng = [for (var i = 0; i < 256; i++) (i * 37 + 5) & 0xff];
    expect(() => cpc2Description([sec('CPC2', rng)]), returnsNormally);
  });
}
