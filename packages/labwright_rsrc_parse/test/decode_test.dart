import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Wraps [payload] as a stored heap section: [u32 decompressedSize][zlib stream].
Uint8List compressedSection(List<int> payload) {
  final z = const ZLibEncoder().encode(payload);
  final b = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List())
    ..add(z);
  return b.toBytes();
}

ViSection sec(String tag, Uint8List bytes) => ViSection(tag: tag, index: 0, dataOffset: 0, bytes: bytes);

void main() {
  test('inflates a [size][zlib] heap section back to the original bytes', () {
    final payload = List<int>.generate(2000, (i) => (i * 7) % 251);
    final dec = inflateSection(sec('BDEx', compressedSection(payload)));
    expect(dec.wasCompressed, isTrue);
    expect(dec.bytes, payload);
    expect(dec.tag, 'BDEx');
  });

  test('an uncompressed section passes through unchanged', () {
    final raw = Uint8List.fromList([1, 2, 3, 4, 5]);
    final dec = inflateSection(sec('CONP', raw));
    expect(dec.wasCompressed, isFalse);
    expect(dec.bytes, raw);
  });

  test('a corrupt "compressed-looking" section falls back to raw, never throws', () {
    final b = Uint8List.fromList([0, 0, 0, 99, 0x78, 0x9c, 1, 2, 3]);
    final dec = inflateSection(sec('X', b));
    expect(dec.wasCompressed, isFalse);
    expect(dec.bytes, b);
  });

  test('size-mismatch (valid zlib, wrong declared size) falls back to raw', () {
    final z = const ZLibEncoder().encode([1, 2, 3]);
    final b = BytesBuilder()
      ..add((ByteData(4)..setUint32(0, 999)).buffer.asUint8List())
      ..add(z);
    final dec = inflateSection(sec('Y', b.toBytes()));
    expect(dec.wasCompressed, isFalse);
  });

  test('decodeSections is total over arbitrary bytes (ViFormatException or list)', () {
    final rng = Random(3);
    for (var i = 0; i < 3000; i++) {
      final n = rng.nextInt(300);
      final bytes = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        expect(decodeSections(bytes), isA<List<DecodedSection>>());
      } on ViFormatException {
        // acceptable: decodeSections may reject malformed input
      } catch (e) {
        fail('decodeSections leaked ${e.runtimeType}: $e');
      }
    }
  });
}
