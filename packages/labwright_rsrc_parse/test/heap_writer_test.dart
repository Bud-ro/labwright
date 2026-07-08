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

  test('a non-rectangle C4 record models only its length-prefixed header', () {
    // Leading u32 + `C4 22 03 "ABC"` (a caption: string shape, lossy interior).
    final body = hx('0000000a c42203414243');
    final res = serializeHeapBody(body);
    expect(res.bytes, equals(body));
    expect(res.modelBytes, 3, reason: 'the C4 <op> <len> header is modeled');
    expect(res.copiedBytes, 4 + 3, reason: 'leading u32 + the string payload are copied');
    expect(res.modelBugs, 0);
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
