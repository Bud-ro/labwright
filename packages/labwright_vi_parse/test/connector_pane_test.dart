import 'dart:typed_data';

import 'package:labwright_vi_parse/labwright_vi_parse.dart';
import 'package:test/test.dart';

void main() {
  group('decodeConnectorPane', () {
    test('the common 2-byte form is a big-endian VCTP index', () {
      final p = decodeConnectorPane(Uint8List.fromList([0x00, 0x2a]))!;
      expect(p.typeIndex, 0x2a);
      expect(p.isInline, isFalse);
      expect(p.rawLength, 2);
      // a larger index
      expect(decodeConnectorPane(Uint8List.fromList([0x01, 0x05]))!.typeIndex, 0x105);
    });

    test('a longer (older) block is flagged inline, not guessed', () {
      final inline = Uint8List.fromList(List.filled(28, 0));
      final p = decodeConnectorPane(inline)!;
      expect(p.isInline, isTrue);
      expect(p.typeIndex, isNull);
      expect(p.rawLength, 28);
    });

    test('empty buffer yields null', () {
      expect(decodeConnectorPane(Uint8List(0)), isNull);
    });

    test('the CONP/CPC2 catalog entries are confirmed connector-pane blocks', () {
      expect(blockInfo('CONP').category, ViBlockCategory.connectorPane);
      expect(blockInfo('CONP').confidence, BlockConfidence.confirmed);
      expect(blockInfo('CPC2').category, ViBlockCategory.connectorPane);
    });
  });
}
