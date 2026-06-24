import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Direct per-branch tests of heapDecodeTier — the single source of truth for the
// 3-tier coverage metric. Each crafted record is classified standalone so a
// mis-tiering can't silently inflate the corpus % and get re-baselined.
HeapDecodeTier tier(List<int> bytes, {String tag = 'BDHb'}) =>
    heapDecodeTier(Uint8List.fromList(bytes), 0, bytes[0], tag);

void main() {
  test('semantic: object header, group open/close, typed ref, decoded C4, named attr', () {
    expect(tier([0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x2a]), HeapDecodeTier.semantic); // object header
    expect(tier([0x08, 0x55]), HeapDecodeTier.semantic); // group close
    expect(tier([0x10, 0xe1, 0x01, 0xfb, 0x00, 0x07]), HeapDecodeTier.semantic); // group open (type tag)
    expect(tier([0x14, 0x19, 0x01, 0xfd, 0x00, 0x09]), HeapDecodeTier.semantic); // childRef
    expect(tier([0xc4, 0x2d, 0x08, 0, 0, 0, 0, 0, 10, 0, 20]), HeapDecodeTier.semantic); // C4 bounds (isDecoded)
    expect(tier([0x84, 0x28, 0xff, 0x12, 0x34, 0x56]), HeapDecodeTier.semantic); // backgroundColor (confirmed)
  });

  test('valueKindKnown: a kindOnly attribute and the 0xE7 opaque container', () {
    // 0x45 0xe7 = fpControlAttr (kindOnly) in u16 form -> value-kind-known.
    expect(tier([0x45, 0xe7, 0x02, 0x08]), HeapDecodeTier.valueKindKnown);
    // C5 E7 <len> opaque container -> value-kind-known (NOT semantic — contents undecoded).
    expect(tier([0xc5, 0xe7, 0x06, 0x03, 0, 0, 0, 0, 0]), HeapDecodeTier.valueKindKnown);
  });

  test('framed: the 0x53 literal ref, an undecoded C4, a bare 0x04 token, an unknown opcode', () {
    expect(tier([0x14, 0x53, 0x01, 0xfd, 0x00, 0x07]), HeapDecodeTier.framed); // 14 53 literal (not a ref)
    expect(tier([0xc4, 0x99, 0x00]), HeapDecodeTier.framed); // C4 with an uncatalogued opcode
    expect(tier([0x04, 0x20]), HeapDecodeTier.framed); // bare 04-token (no longer credited semantic)
    expect(tier([0x99, 0x00]), HeapDecodeTier.framed); // unknown lead
  });
}
