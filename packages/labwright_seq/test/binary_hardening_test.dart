library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Fuzz-hardening guards on the binary decoder: hostile inputs must be
/// TOTAL (return null / bail), never crash or exhaust memory. These use
/// crafted bytes, not the corpus, so they run without the `corpus` tag.
void main() {
  // A minimal binary TOF1 file: the 'TOF1' magic followed by [tail].
  Uint8List tof1(List<int> tail) =>
      Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, ...tail]);

  test('a zlib decompression bomb aborts instead of exhausting memory', () {
    // ~1 MB of zeros deflates to a couple KB but would inflate far past
    // the cap were it repeated; here we confirm a body well over the cap
    // is rejected (null) rather than materialized. Build a stream that
    // inflates to > the cap by compressing a large zero run.
    final bomb = ZLibEncoder().convert(Uint8List(200 * 1024 * 1024));
    // Sanity: the compressed bomb is tiny, the inflated size is huge.
    expect(bomb.length, lessThan(1 * 1024 * 1024));
    final file = tof1(bomb);
    // Must return null (over-cap) — and, crucially, must return at all
    // (no OOM): reaching the expect proves the cap fired.
    expect(inflateBinaryBody(file), isNull);
  });

  test('a body just under the cap still inflates', () {
    final ok = ZLibEncoder().convert(Uint8List(1024 * 1024));
    expect(inflateBinaryBody(tof1(ok)), isNotNull);
  });

  test('a non-binary file yields null, never throws', () {
    expect(inflateBinaryBody(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
    expect(
        inflateBinaryBody(Uint8List.fromList('<?xml version="1.0"?>'.codeUnits)),
        isNull);
  });

  test('deeply nested typedef bodies bail instead of overflowing the stack',
      () {
    // A record region built entirely of self-nesting descriptor nodes —
    // each `[0][0][DELIM][nameIdx][childCount=1]` recurses one level per
    // 20 bytes. Without a depth cap this overflows the Dart stack; with
    // it, the parse must terminate (return no decoded body) and never
    // throw. We drive it through the public parseSeqFile on a crafted
    // inflated body.
    //
    // Constructing a fully valid TOF1 record layout by hand is involved;
    // the guarantee under test — totality on hostile input — is that the
    // call returns without a StackOverflowError. A body of 100k nested
    // headers (~2 MB) would blow a ~10k-frame stack were the guard
    // absent.
    final region = BytesBuilder();
    void u32(int v) => region.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);
    for (var i = 0; i < 100000; i++) {
      u32(0); // flags
      u32(0); // zero slot
      u32(0xffffffff); // delimiter in the class slot
      u32(1); // nameIdx (pool index)
      u32(1); // childCount = 1 → recurse
    }
    final body = region.toBytes();
    final compressed = ZLibEncoder().convert(body);
    final file = tof1(compressed);
    // The parser may find no valid layout at all (fine) — the assertion
    // is that this returns/normalizes without throwing StackOverflowError.
    expect(() => parseSeqFile(file), returnsNormally);
    // And the low-level lens over the same bytes is equally total.
    expect(() => binaryTypeRecords(file), returnsNormally);
  });
}
