import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Unit pins for the [ViSignalType] wire-type-word decode
/// (`[flags][depth][element type code]`) on corpus-observed values, and for
/// the heap capture that surfaces it as [ViWire.signalType].
void main() {
  test('wire-type word decode', () {
    // (raw, code, depth, flags, dataType, elementKind, arrayDims, typeKind)
    const cases = <(int, int, int, int, ViDataType?, ViTypeKind?, int?, ViTypeKind?)>[
      (0x103, 0x03, 1, 0, ViDataType.i32, ViTypeKind.numericInt, 0, ViTypeKind.numericInt),
      (0x10a, 0x0a, 1, 0, ViDataType.dbl, ViTypeKind.numericFloat, 0, ViTypeKind.numericFloat),
      (0x121, 0x21, 1, 0, ViDataType.boolean, ViTypeKind.boolean, 0, ViTypeKind.boolean),
      (0x4230, 0x30, 2, 4, ViDataType.string, ViTypeKind.string, 0, ViTypeKind.string),
      (0x232, 0x32, 2, 0, ViDataType.path, ViTypeKind.path, 0, ViTypeKind.path),
      (0x8350, 0x50, 3, 8, ViDataType.cluster, ViTypeKind.cluster, 0, ViTypeKind.cluster),
      (0x351, 0x51, 3, 0, ViDataType.cluster, ViTypeKind.cluster, 0, ViTypeKind.cluster),
      (0x170, 0x70, 1, 0, ViDataType.refnum, ViTypeKind.refnum, null, ViTypeKind.refnum),
      (0x8571, 0x71, 5, 8, ViDataType.refnum, ViTypeKind.refnum, null, ViTypeKind.refnum),
      (0x203, 0x03, 2, 0, ViDataType.i32, ViTypeKind.numericInt, 1, ViTypeKind.array),
      (0x330, 0x30, 3, 0, ViDataType.string, ViTypeKind.string, 1, ViTypeKind.array),
      (0x430, 0x30, 4, 0, ViDataType.string, ViTypeKind.string, 2, ViTypeKind.array),
      (0x8450, 0x50, 4, 8, ViDataType.cluster, ViTypeKind.cluster, 1, ViTypeKind.array),
      (0x8354, 0x54, 3, 8, ViDataType.measureData, null, 0, null),
      (0x83ff, 0xff, 3, 8, null, null, null, null),
    ];
    for (final (raw, code, depth, flags, dataType, elementKind, dims, kind) in cases) {
      final t = ViSignalType(raw);
      final label = '0x${raw.toRadixString(16)}';
      expect(t.typeCode, code, reason: label);
      expect(t.depth, depth, reason: label);
      expect(t.flags, flags, reason: label);
      expect(t.dataType, dataType, reason: label);
      expect(t.elementKind, elementKind, reason: label);
      expect(t.arrayDims, dims, reason: label);
      expect(t.typeKind, kind, reason: label);
      // Tristate arrayness: unknown dims (refnum / uncatalogued codes) stay
      // an honest null, never false.
      expect(t.isArray, dims == null ? null : dims > 0, reason: label);
    }
  });

  test('value equality on the raw word', () {
    expect(const ViSignalType(0x8350), const ViSignalType(0x8350));
    expect(const ViSignalType(0x8350).hashCode, const ViSignalType(0x8350).hashCode);
    expect(const ViSignalType(0x8350), isNot(const ViSignalType(0x0350)));
  });

  test('a signal heap object surfaces its wire-type word on the wire', () {
    // Minimal BD heap: root 0x7e holding one signal 0x17 with a `44 9F`
    // lastSignalKind record of 0x0203 (array of i32) and two endpoint refs.
    final body = Uint8List.fromList([
      0, 0, 0, 0, // content length word (unused by the walker)
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x7e, 0xfd, 0x00, 0x01, // root
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x17, 0xfd, 0x00, 0x02, // signal
      0x44, 0x9f, 0x02, 0x03, // lastSignalKind = 0x0203
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x03, // endpoint ref
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x04, // endpoint ref
      0x08, 0x19, // close signal
      0x08, 0x19, // close root
    ]);
    final wires = buildDiagram(body).wires;
    expect(wires, hasLength(1));
    expect(wires.single.signalType?.raw, 0x0203);
    expect(wires.single.typeKind, ViTypeKind.array);
    expect(wires.single.elementTypeKind, ViTypeKind.numericInt);
  });

  test('a signal with no wire-type record yields honest nulls', () {
    // Same minimal heap, no `44 9F` record on the signal.
    final body = Uint8List.fromList([
      0, 0, 0, 0,
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x7e, 0xfd, 0x00, 0x01, // root
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x17, 0xfd, 0x00, 0x02, // signal
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x03, // endpoint ref
      0x08, 0x19, // close signal
      0x08, 0x19, // close root
    ]);
    final wire = buildDiagram(body).wires.single;
    expect(wire.signalType, isNull);
    expect(wire.typeKind, isNull);
    expect(wire.elementTypeKind, isNull);
  });

  test('an uncatalogued code yields a word but no family', () {
    // `44 9F` with 0x83FF: framed and surfaced raw, family honestly null.
    final body = Uint8List.fromList([
      0, 0, 0, 0,
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x7e, 0xfd, 0x00, 0x01, // root
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x17, 0xfd, 0x00, 0x02, // signal
      0x44, 0x9f, 0x83, 0xff, // lastSignalKind = 0x83ff
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x03, // endpoint ref
      0x08, 0x19, // close signal
      0x08, 0x19, // close root
    ]);
    final wire = buildDiagram(body).wires.single;
    expect(wire.signalType?.raw, 0x83ff);
    expect(wire.typeKind, isNull);
    expect(wire.elementTypeKind, isNull);
    expect(wire.signalType?.isArray, isNull);
  });
}
