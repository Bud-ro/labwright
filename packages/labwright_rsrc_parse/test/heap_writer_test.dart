import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

/// A synthetic inflated heap body: leading `u32` content-length, then one record
/// of each model-sourced family (object header, bounds `C4`, `u16` attribute,
/// typed reference, group close).
final _body = hx(
  '00000020' // leading u32 content-length (framing, copied)
  '101902fe0009fd0005' // object header: 10 19 02 fe <kind 9> fd <oid 5>       (9 B)
  'c42d080001000200030004' // C4 2D bounds: 4x s16 (1,2,3,4)                  (11 B)
  '44df0010' // 44 df: u16 attribute (raw 0x0df) value 0x0010                  (4 B)
  '144f01fd0007' // 14 4f: dcoRef -> oid 7                                      (6 B)
  '0800', // 08 00: group close                                               (2 B)
);

void main() {
  test('serializeHeapBody re-emits byte-exact and models every framed record', () {
    final res = serializeHeapBody(_body);
    expect(res.bytes, equals(_body));
    expect(res.modelBytes, 9 + 11 + 4 + 6 + 2, reason: 'all five records are model-sourced');
    expect(res.copiedBytes, 4, reason: 'only the leading u32 content-length is copied');
    expect(res.modelBugs, 0);
    expect(res.modelBytes + res.copiedBytes, res.bytes.length);
  });

  test('a C4 string record models its header plus its retained interior', () {
    // Leading u32 + `C4 22 03 "ABC"` (a caption: string shape). The header is
    // reconstructed and the 3-byte string payload is retained byte-faithfully.
    final body = hx('0000000a c42203414243');
    final res = serializeHeapBody(body);
    expect(res.bytes, equals(body));
    expect(res.modelBytes, 3 + 3, reason: 'the C4 <op> <len> header + the retained string bytes');
    expect(res.copiedBytes, 4, reason: 'only the leading u32 content-length is copied');
    expect(res.modelBugs, 0);
  });

  test('a C4 string record with non-printable bytes still re-emits byte-exact', () {
    // `C4 22 04` then a 4-byte payload with a control byte (0x01): the display
    // decode (HeapRecord.text) drops it, but rawText retains every byte so the
    // record models whole and re-emits exactly.
    final body = hx('0000000b c4220441420143');
    final res = serializeHeapBody(body);
    expect(res.bytes, equals(body));
    expect(res.modelBytes, 3 + 4, reason: 'header + the retained (unfiltered) payload');
    expect(res.copiedBytes, 4);
    expect(res.modelBugs, 0);
  });

  test('a VCTP body re-serializes byte-exact and models the whole pool', () {
    // count=2, TD0 (descLen 6), TD1 (descLen 8), top-level list [2](0,1).
    final body = hx(
      '00000002' // u32 count = 2
      '0006 0005 1122' // TD0: descLen 6, interior <flags 00><code 05> 11 22
      '0008 0040 aabbccdd' // TD1: descLen 8, interior <00><40 array> aa bb cc dd
      '0002 0000 0001', // top-level list: count 2, indices 0 and 1
    );
    final res = serializeHeapBody(body, 'VCTP');
    expect(res.bytes, equals(body));
    expect(res.modelBytes, body.length, reason: 'the whole pool frames: structural words + retained interiors');
    expect(res.copiedBytes, 0);
    expect(res.modelBugs, 0);

    final split = attributeHeapBody(body, 'VCTP');
    expect(split.modelBytes, body.length);
    expect(split.copiedBytes, 0);
    expect(split.modelBugs, 0);
  });

  test('a VCTP body that does not tile stays copied and byte-exact', () {
    // count claims 3 descriptors but the body holds only one — the grammar
    // rejects it, so the whole body is copied (byte-exactness preserved).
    final body = hx('00000003 0006 0005 1122');
    final res = serializeHeapBody(body, 'VCTP');
    expect(res.bytes, equals(body));
    expect(res.modelBytes, 0);
    expect(res.copiedBytes, body.length);
    expect(attributeHeapBody(body, 'VCTP').copiedBytes, body.length);
  });

  test('serializeHeapBody is total and byte-exact on random VCTP-tagged buffers', () {
    expectTotal(7, 2000, 64, (b) {
      final res = serializeHeapBody(b, 'VCTP');
      expect(res.bytes, equals(b));
      expect(res.modelBytes + res.copiedBytes, b.length);
      expect(res.modelBugs, 0);
    });
  });

  test('serializeHeapBody is total and always byte-exact on random buffers', () {
    expectTotal(1, 4000, 64, (b) {
      final res = serializeHeapBody(b);
      expect(res.bytes, equals(b));
      expect(res.modelBytes + res.copiedBytes, b.length);
      expect(res.modelBugs, 0);
    });
  });

  test('deflate/inflate heap payload round-trips the content', () {
    final content = u8([for (var i = 0; i < 500; i++) (i * 7) & 0xff]);
    final payload = deflateHeapPayload(content);
    expect(isCompressedHeapPayload(payload), isTrue);
    expect(inflateHeapPayload(payload), equals(content));
    expect(reDeflatePreservesContent(payload), isTrue);
  });

  test('reDeflatePreservesContent returns null for a non-compressed payload', () {
    expect(reDeflatePreservesContent(u8([1, 2, 3, 4, 5, 6])), isNull);
  });
}
