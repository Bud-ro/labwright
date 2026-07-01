import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

Uint8List _pth0(List<String> comps, {int type = 0}) {
  final body = BytesBuilder();
  for (final c in comps) {
    body.add([c.length, ...c.codeUnits]);
  }
  final compBytes = body.toBytes();
  final b = BytesBuilder();
  void be16(int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
  b.add('PTH0'.codeUnits);
  be32(2 + 2 + compBytes.length); // 2+2 = i16 pathType + i16 componentCount
  be16(type);
  be16(comps.length);
  b.add(compBytes);
  return Uint8List.fromList(b.toBytes());
}

void main() {
  group('decodeHelpPath', () {
    test('parses a PTH0 path into components + joined path', () {
      final p = decodeHelpPath(_pth0(['<helpdir>', 'JKI', 'Caraya', 'README.html']))!;
      expect(p.isPth0, isTrue);
      expect(p.pathType, 0);
      expect(p.components, ['<helpdir>', 'JKI', 'Caraya', 'README.html']);
      expect(p.path, '<helpdir>/JKI/Caraya/README.html');
    });

    test('non-PTH0 bytes are flagged, not guessed', () {
      final p = decodeHelpPath(Uint8List.fromList(List.filled(16, 0x41)))!;
      expect(p.isPth0, isFalse);
      expect(p.components, isEmpty);
    });

    test('too short yields null; a lying count does not throw', () {
      expect(decodeHelpPath(Uint8List(8)), isNull);
      final b = _pth0(['a']);
      ByteData.sublistView(b).setUint16(10, 9999);
      expect(decodeHelpPath(b)!.components.length, lessThanOrEqualTo(1),
          reason: 'a lying (huge) component count bails at buffer end without throwing');
    });

    test('HLPT reuses the STRG [u32 len][text] layout', () {
      final body = '### Foo.vi'.codeUnits;
      final b = Uint8List(4 + body.length);
      ByteData.sublistView(b).setUint32(0, body.length);
      b.setRange(4, b.length, body);
      expect(decodeStringBlock(b), '### Foo.vi',
          reason: 'helpTextFromSections delegates to decodeStringBlock, the shared STRG/HLPT decoder');
    });

    test('catalog: HLPP help-path, HLPT confirmed text', () {
      expect(blockInfo('HLPP').category, ViBlockCategory.helpPath);
      expect(blockInfo('HLPP').confidence, BlockConfidence.confirmed);
      expect(blockInfo('HLPT').category, ViBlockCategory.text);
      expect(blockInfo('HLPT').confidence, BlockConfidence.confirmed);
    });
  });
}
