import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

Uint8List _strg(String text) {
  final body = utf8.encode(text);
  final b = Uint8List(4 + body.length);
  ByteData.sublistView(b).setUint32(0, body.length);
  b.setRange(4, b.length, body);
  return b;
}

void main() {
  group('decodeStringBlock', () {
    test('reads [u32 len][text]', () {
      expect(decodeStringBlock(_strg('This VI does X')), 'This VI does X');
      expect(decodeStringBlock(_strg('')), '');
    });

    test('decodes UTF-8 leniently and never throws', () {
      // length says 6 but only 3 body bytes present -> clamps, no throw.
      final b = Uint8List.fromList([0, 0, 0, 6, 0x41, 0x42, 0x43]);
      expect(decodeStringBlock(b), 'ABC');
      // a stray high byte becomes the replacement char rather than throwing.
      final bad = Uint8List.fromList([0, 0, 0, 1, 0xff]);
      expect(decodeStringBlock(bad), isNotNull);
    });

    test('too short for the length prefix yields null', () {
      expect(decodeStringBlock(Uint8List.fromList([0, 0, 0])), isNull);
    });

    test('the STRG catalog entry is confirmed text', () {
      expect(blockInfo('STRG').category, ViBlockCategory.text);
      expect(blockInfo('STRG').confidence, BlockConfidence.confirmed);
    });
  });
}
