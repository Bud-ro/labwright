import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Classifies one crafted record with [heapDecodeTier], the single source of
/// truth for the 3-tier coverage metric. Each record is tiered standalone so a
/// mis-tiering can't silently inflate the corpus % and get re-baselined.
HeapDecodeTier tier(List<int> bytes, {String tag = 'BDHb'}) =>
    heapDecodeTier(Uint8List.fromList(bytes), 0, bytes[0], tag);

void main() {
  test('semantic: object header, group open/close, typed ref, decoded C4, named attr', () {
    expect(tier([0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x2a]), HeapDecodeTier.semantic, reason: 'object header');
    expect(tier([0x08, 0x55]), HeapDecodeTier.semantic, reason: 'group close');
    expect(tier([0x10, 0xe1, 0x01, 0xfb, 0x00, 0x07]), HeapDecodeTier.semantic, reason: 'group open (type tag)');
    expect(tier([0x14, 0x19, 0x01, 0xfd, 0x00, 0x09]), HeapDecodeTier.semantic, reason: 'childRef');
    expect(tier([0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]), HeapDecodeTier.semantic, reason: 'C4 bounds (isDecoded)');
    expect(tier([0x84, 0x28, 0xff, 0x12, 0x34, 0x56]), HeapDecodeTier.semantic, reason: 'backgroundColor (confirmed)');
    expect(tier([0x84, 0x2a, 0xff, 0xff, 0x42, 0x42]), HeapDecodeTier.semantic, reason: 'plotColor (inferred)');
    expect(tier([0x84, 0x2b, 0xff, 0xbc, 0xbc, 0xbc]), HeapDecodeTier.semantic, reason: 'areaFillColor (inferred)');
  });

  test('valueKindKnown: kindOnly attr, 0xE7 container, and known-shape C4 (rect/container)', () {
    expect(tier([0x45, 0xe7, 0x02, 0x08]), HeapDecodeTier.valueKindKnown,
        reason: '0x45 0xe7 = fpControlAttr (kindOnly) in u16 form');
    expect(tier([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]), HeapDecodeTier.valueKindKnown,
        reason: 'C5 E7 opaque container: contents undecoded, not semantic');
    expect(tier([0xc4, 0x5f, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]), HeapDecodeTier.valueKindKnown,
        reason: 'C4 5F = rect5f: decoded rectangle shape but role undetermined (not isDecoded)');
    expect(tier([0xc4, 0x44, 0x00]), HeapDecodeTier.valueKindKnown,
        reason: 'C4 44 = container44: known container shape, contents not decoded');
  });

  test('semantic: newest decoded forms (0x31 string, 0x6c help blob, 0x20/0x21/0x22 f64, colour)', () {
    expect(tier([0xc6, 0x31, 0x05, ...'Scale'.codeUnits]), HeapDecodeTier.semantic,
        reason: '0x31 inline property-name string');
    expect(tier([0xc6, 0x6c, 0xff, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x06, ...'Robot!'.codeUnits]), HeapDecodeTier.semantic,
        reason: '0x6c help-text blob (C6 6C FF <u16 len> <u32 strlen> ascii)');
    expect(tier([0xc5, 0x20, 0x08, 0xbf, 0xf0, 0, 0, 0, 0, 0, 0]), HeapDecodeTier.semantic,
        reason: '0x20 in the C5 …08 f64 form = control min');
    expect(tier([0xc5, 0x22, 0x08, 0, 0, 0, 0, 0, 0, 0, 0]), HeapDecodeTier.semantic,
        reason: '0x22 in the C5 …08 f64 form = control default');
    expect(tier([0x84, 0x20, 0xff, 0x10, 0x10, 0x10]), HeapDecodeTier.semantic,
        reason: '0x20 in the rgb (84) colour form is still semantic');
  });

  test('valueKindKnown: a colour-named id in a NON-colour width is not credited as a colour', () {
    expect(tier([0x45, 0x20, 0x02, 0x00]), HeapDecodeTier.valueKindKnown,
        reason: '0x20 as u16 (45) carries a packed int, not a colour');
    expect(tier([0x44, 0x21, 0x12, 0x34]), HeapDecodeTier.valueKindKnown,
        reason: '0x21 as u16 (44) carries a packed int, not a colour');
    expect(tier([0x24, 0x20, 0x05]), HeapDecodeTier.valueKindKnown,
        reason: '0x20 as u8 (24) carries a packed int, not a colour');
  });

  test('framed: the 0x53 literal ref, an undecoded C4, a bare 0x04 token, an unknown opcode', () {
    expect(tier([0x14, 0x53, 0x01, 0xfd, 0x00, 0x07]), HeapDecodeTier.framed, reason: '14 53 literal (not a ref)');
    expect(tier([0xc4, 0x99, 0x00]), HeapDecodeTier.framed, reason: 'C4 with an uncatalogued opcode');
    expect(tier([0x04, 0x20]), HeapDecodeTier.framed, reason: 'bare 04-token (no longer credited semantic)');
    expect(tier([0x99, 0x00]), HeapDecodeTier.framed, reason: 'unknown lead byte');
  });
}
