import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

void main() {
  test('inflateBinaryBody locates + inflates the TOF1 zlib body', () {
    final payload = ascii.encode('SequenceFileData...MainSequence...Step' * 4);
    final compressed = zlib.encode(payload);
    // A TOF1 header (magic + type token) with a preamble, then the zlib stream.
    final b = BytesBuilder()
      ..add(ascii.encode('TOF1'))
      ..add(List.filled(6, 0))
      ..add(ascii.encode('SequenceFile'))
      ..add(List.filled(0x100, 0)) // header/preamble padding
      ..add(compressed);
    final body = inflateBinaryBody(Uint8List.fromList(b.toBytes()));
    expect(body, isNotNull);
    expect(ascii.decode(body!), contains('MainSequence'));
  });

  test('returns null for non-binary / arbitrary input (no throw)', () {
    expect(inflateBinaryBody(Uint8List.fromList(ascii.encode('<?xml?>'))), isNull);
    expect(inflateBinaryBody(Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3])), isNull);
    expect(inflateBinaryBody(Uint8List(0)), isNull);
  });
}
