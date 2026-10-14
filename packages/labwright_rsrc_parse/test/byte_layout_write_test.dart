import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

void main() {
  test('each scalar field writes the bytes its reader decodes, in its own width and endianness', () {
    const rows = <(Scalar, int, List<int>)>[
      (U8(1), 0xab, [0, 0xab, 0, 0, 0, 0]),
      (U16(1), 0xabcd, [0, 0xab, 0xcd, 0, 0, 0]),
      (U16(1, endian: Endian.little), 0xabcd, [0, 0xcd, 0xab, 0, 0, 0]),
      (U32(1), 0x01020304, [0, 1, 2, 3, 4, 0]),
      (U32(1, endian: Endian.little), 0x01020304, [0, 4, 3, 2, 1, 0]),
      (I16(1), -2, [0, 0xff, 0xfe, 0, 0, 0]),
      (I32(1), -2, [0, 0xff, 0xff, 0xff, 0xfe, 0]),
      (PackedWord(1), 0x1234, [0, 0x12, 0x34, 0, 0, 0]),
    ];
    for (final (field, value, bytes) in rows) {
      final view = ByteData(6);
      field.write(view, value);
      expect(Uint8List.view(view.buffer), bytes, reason: field.typeName);
      expect(field.read(view), value, reason: field.typeName);
    }
  });

  test('a packed word keeps the width it had; floats, codes and word lists write in place', () {
    final wide = ByteData(4)..setUint32(0, 0x80000005);
    const PackedWord(0).write(wide, 0x12345);
    expect(Uint8List.view(wide.buffer), [0x80, 0x01, 0x23, 0x45]);
    expect(const PackedWord(0).read(wide), 0x12345);
    final view = ByteData(12);
    const F32(0).write(view, 1.5);
    const FourCc(4).write(view, 'LVIN');
    const U16List(8, length: 2).setAt(view, 1, 0x0102);
    expect(const F32(0).read(view), 1.5);
    expect(const FourCc(4).read(view), 'LVIN');
    expect(const U16List(8, length: 2).read(view), [0, 0x0102]);
    const U32List(8, length: 1).setAt(view, 0, 7);
    expect(const U32List(8, length: 1).read(view), [7]);
  });
}
