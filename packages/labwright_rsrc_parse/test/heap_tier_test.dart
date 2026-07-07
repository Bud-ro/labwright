import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Classifies one crafted record with [heapDecodeTier], the single source of
/// truth for the 3-tier coverage metric. Each record is tiered standalone so a
/// mis-tiering can't silently inflate the corpus % and get re-baselined.
/// [enclosingKind] mirrors the class context [measureHeapTiers] supplies.
HeapDecodeTier tier(List<int> bytes, {int enclosingKind = -1}) =>
    heapDecodeTier(Uint8List.fromList(bytes), 0, bytes[0], 'BDHb', enclosingKind: enclosingKind);

void main() {
  test('semantic: object header, group open/close, typed ref, decoded C4, named attr', () {
    expect(
      tier([0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x2a]),
      HeapDecodeTier.semantic,
      reason: 'object header',
    );
    expect(tier([0x08, 0x55]), HeapDecodeTier.semantic, reason: 'group close');
    expect(tier([0x10, 0xe1, 0x01, 0xfb, 0x00, 0x07]), HeapDecodeTier.semantic, reason: 'group open (type tag)');
    expect(tier([0x14, 0x19, 0x01, 0xfd, 0x00, 0x09]), HeapDecodeTier.semantic, reason: 'childRef');
    expect(
      tier([0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]),
      HeapDecodeTier.semantic,
      reason: 'C4 bounds (isDecoded)',
    );
    expect(tier([0x84, 0x28, 0xff, 0x12, 0x34, 0x56]), HeapDecodeTier.semantic, reason: 'backgroundColor (confirmed)');
    expect(tier([0x84, 0x2a, 0xff, 0xff, 0x42, 0x42]), HeapDecodeTier.semantic, reason: 'plotColor (inferred)');
    expect(tier([0x84, 0x2b, 0xff, 0xbc, 0xbc, 0xbc]), HeapDecodeTier.semantic, reason: 'borderColor (inferred)');
  });

  test('semantic: the raw-tag upgrades (objFlags, masterPart, signal chain, cross-heap ddoRef, refs)', () {
    expect(tier([0x64, 0xcb, 0x10, 0x00, 0x00]), HeapDecodeTier.semantic, reason: 'raw 0x0CB objFlags (inferred)');
    expect(tier([0x24, 0xaf, 0x09]), HeapDecodeTier.semantic, reason: 'raw 0x0AF masterPart (inferred)');
    expect(
      tier([0x45, 0xe7, 0x02, 0x08]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x1E7 compressedWireTable, small scalar form',
    );
    expect(
      tier([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x1E7 compressedWireTable, container form (record meaning known; interior packing not)',
    );
    expect(tier([0x44, 0x9f, 0x83, 0x50]), HeapDecodeTier.semantic, reason: 'raw 0x09F lastSignalKind (inferred)');
    expect(tier([0x14, 0x53, 0x01, 0xfd, 0x00, 0x07]), HeapDecodeTier.semantic, reason: 'ddoRef (cross-heap, 100%)');
    expect(tier([0x15, 0x13, 0x01, 0xfd, 0x00, 0x07]), HeapDecodeTier.semantic, reason: 'srcDCORef (15-lead leaf ref)');
    expect(
      tier([0x16, 0x8a, 0x01, 0xfd, 0x00, 0x07]),
      HeapDecodeTier.semantic,
      reason: 'attachmentRef (16-lead leaf ref)',
    );
    expect(
      tier([0xc4, 0x5f, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]),
      HeapDecodeTier.semantic,
      reason: 'C4 5F = docBounds (decoded rect role)',
    );
  });

  test('valueKindKnown: kindOnly attrs, unknown tags, and known-shape C4 (rect/container)', () {
    expect(
      tier([0xc4, 0x44, 0x00]),
      HeapDecodeTier.valueKindKnown,
      reason: 'C4 44 = container44: known container shape, contents not decoded',
    );
    expect(
      tier([0xc4, 0x26, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]),
      HeapDecodeTier.valueKindKnown,
      reason: 'C4 26 = rect26: structural rect, role undetermined',
    );
    expect(
      tier([0x24, 0x99, 0x05]),
      HeapDecodeTier.valueKindKnown,
      reason: 'uncatalogued tag with a grammar-known width: value known, meaning not',
    );
    expect(
      tier([0x24, 0x23, 0x01]),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x023 field23 stays kindOnly (no coherent corpus axis)',
    );
    expect(
      tier([0x14, 0x53, 0x01, 0xfe, 0x00, 0x34]),
      HeapDecodeTier.valueKindKnown,
      reason: 'leaf with an fe (class) attribute: structure known, tag meaning not',
    );
    expect(
      tier([0x15, 0x77, 0x01, 0xfd, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00]),
      HeapDecodeTier.valueKindKnown,
      reason: 'fd-escape leaf (7-byte value form): structure known, not decoded as a compact ref',
    );
    expect(
      tier([0x15, 0x99, 0x24, 0xdf]),
      HeapDecodeTier.valueKindKnown,
      reason: 'uncatalogued bare 2-byte selector: boundary + empty value known',
    );
  });

  test('semantic: string/f64 forms (0x231 name, 0x26C const text, 0x220 stdNumMin f64)', () {
    expect(
      tier([0xc6, 0x31, 0x05, ...'Scale'.codeUnits]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x231 inline property-item-name string',
    );
    expect(
      tier([0xc6, 0x6c, 0xff, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x26C constant-value text blob (C6 6C FF <u16 len> <u32 strlen> ascii)',
    );
    expect(
      tier([0xc6, 0x20, 0x08, 0xbf, 0xf0, 0, 0, 0, 0, 0, 0]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x220 stdNumMin f64 (C6 20 08)',
    );
    expect(
      tier([0xc6, 0x22, 0x08, 0, 0, 0, 0, 0, 0, 0, 0]),
      HeapDecodeTier.semantic,
      reason: 'raw 0x222 stdNumInc f64 (C6 22 08)',
    );
  });

  test('semantic: partRole (0xDF, inferred) lands in the semantic tier in both widths', () {
    expect(
      tier([0x24, 0xdf, 66]),
      HeapDecodeTier.semantic,
      reason: 'partRole u8 form (value 66 = annex part role)',
    );
    expect(
      tier([0x44, 0xdf, 0x1f, 0x42]),
      HeapDecodeTier.semantic,
      reason: 'partRole u16 form (value 8002 = numeric-control role)',
    );
  });

  test('class-polymorphic colour tags 0x020/0x021: colour only in the cosm classes', () {
    expect(
      tier([0x84, 0x20, 0xff, 0x10, 0x10, 0x10], enclosingKind: 0x0c),
      HeapDecodeTier.semantic,
      reason: 'raw 0x020 u32 inside bigMultiCosm = a colour (99.38% of u32 records)',
    );
    expect(
      tier([0x84, 0x20, 0xff, 0x10, 0x10, 0x10], enclosingKind: 0x0a),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x020 u32 inside a label class is a text-style word, not credited as colour',
    );
    expect(
      tier([0x84, 0x21, 0x00, 0x81, 0x44, 0x04]),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x021 u32 with no known enclosing class stays value-kind-known',
    );
    expect(
      tier([0x45, 0x20, 0x02, 0x00]),
      HeapDecodeTier.semantic,
      reason: '45 20 is raw 0x120 = tableFlags (a different tag than 44 20 = raw 0x020)',
    );
  });

  test('valueKindKnown: a colour-named tag in a NON-colour width is not credited as a colour', () {
    expect(
      tier([0x44, 0x21, 0x12, 0x34]),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x021 as u16 carries a text-mode word, not a colour',
    );
    expect(
      tier([0x24, 0x20, 0x05]),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x020 as u8 carries a small index, not a colour',
    );
    expect(
      tier([0x24, 0x28, 0x01]),
      HeapDecodeTier.valueKindKnown,
      reason: 'raw 0x028 bgColor at u8 width: colour-ness of the narrow form not established',
    );
  });

  test('tail tiers: an uncatalogued C4 opcode is valueKind (framed payload); an unknown lead is framed', () {
    expect(
      tier([0xc4, 0x99, 0x00]),
      HeapDecodeTier.valueKindKnown,
      reason: 'C4 with an uncatalogued opcode: length-prefixed payload extent known, meaning not',
    );
    expect(tier([0x99, 0x00]), HeapDecodeTier.framed, reason: 'unknown lead byte');
  });
}
