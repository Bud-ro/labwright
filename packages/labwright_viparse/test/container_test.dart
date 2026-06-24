import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

/// Builds a minimal well-formed RSRC container: 32-byte header (magic + the
/// dataOffset/dataSize/infoOffset words) ++ data area ++ info area.
Uint8List _container(List<int> data, List<int> info) {
  final header = Uint8List(32);
  header.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]); // RSRC\r\n
  final hd = ByteData.sublistView(header);
  const dataOffset = 32;
  final infoOffset = dataOffset + data.length;
  hd.setUint32(16, infoOffset);
  hd.setUint32(24, dataOffset);
  hd.setUint32(28, data.length);
  return Uint8List.fromList([...header, ...data, ...info]);
}

void main() {
  group('ViContainer', () {
    test('parse → toBytes is byte-exact for an unmodified container', () {
      final bytes = _container([1, 2, 3, 4, 5], [9, 8, 7]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length, 32);
      expect(c.dataArea, orderedEquals([1, 2, 3, 4, 5]));
      expect(c.infoArea, orderedEquals([9, 8, 7]));
      expect(c.toBytes(), orderedEquals(bytes)); // the idempotency contract
    });

    test('rejects a non-RSRC / mis-ordered container', () {
      expect(() => ViContainer.parse(Uint8List(10)), throwsA(isA<ViFormatException>())); // bad magic
      // infoOffset before dataOffset (mis-ordered) must be rejected, not silently mangled.
      final bad = _container([1, 2, 3, 4], const []);
      ByteData.sublistView(bad).setUint32(16, 8); // infoOffset=8 < dataOffset=32
      expect(() => ViContainer.parse(bad), throwsA(isA<ViFormatException>()));
    });

    test('the three regions partition the whole file with no gap/overlap', () {
      final bytes = _container([10, 20, 30], [40, 50]);
      final c = ViContainer.parse(bytes);
      expect(c.header.length + c.dataArea.length + c.infoArea.length, bytes.length);
    });
  });

  group('ViExport.rebuildDataArea', () {
    test('serializes sections as [u32 len][payload] and gaps verbatim', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: Uint8List.fromList([1, 2, 3])),
        ViGap(Uint8List.fromList([0, 0])),
        ViSectionData(secRel: 9, payload: Uint8List.fromList([9])),
      ]);
      expect(out, orderedEquals([
        0, 0, 0, 3, 1, 2, 3, // section: len=3 + payload
        0, 0, //                 gap
        0, 0, 0, 1, 9, //        section: len=1 + payload
      ]));
    });

    test('editing a payload recomputes its length prefix', () {
      final out = ViExport.rebuildDataArea([
        ViSectionData(secRel: 0, payload: Uint8List.fromList([7, 7, 7, 7, 7])), // grew to 5
      ]);
      expect(out, orderedEquals([0, 0, 0, 5, 7, 7, 7, 7, 7]));
    });
  });
}
