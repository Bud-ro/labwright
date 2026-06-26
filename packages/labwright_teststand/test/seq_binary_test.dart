import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

/// Builds a fake TOF1 file: header + preamble + a zlib stream of [bodyBytes].
Uint8List _tof1(List<int> bodyBytes) {
  final b = BytesBuilder()
    ..add(ascii.encode('TOF1'))
    ..add(List.filled(6, 0))
    ..add(ascii.encode('SequenceFile'))
    ..add(List.filled(0x100, 0)) // header/preamble padding
    ..add(zlib.encode(bodyBytes));
  return Uint8List.fromList(b.toBytes());
}

void main() {
  test('inflateBinaryBody locates + inflates the TOF1 zlib body', () {
    final body = inflateBinaryBody(_tof1(ascii.encode('SequenceFileData-MainSequence-Step' * 4)));
    expect(body, isNotNull);
    expect(ascii.decode(body!), contains('MainSequence'));
  });

  test('binaryBodyStrings recovers the NUL-terminated name pool', () {
    final pool = <int>[];
    // Padding name first so the inflated body exceeds the >64-byte guard.
    for (final name in ['PaddingNameToExceedTheSixtyFourByteInflateGuardInThisTest',
        'SequenceFileData', 'MainSequence', 'Step', 'Locals']) {
      pool.addAll(ascii.encode(name));
      pool.add(0); // NUL terminator between names, as the real body stores them
    }
    final names = binaryBodyStrings(_tof1(pool)).map((s) => s.text).toList();
    expect(names, containsAll(['SequenceFileData', 'MainSequence', 'Step', 'Locals']));
  });

  test('returns null/empty for non-binary / arbitrary input (no throw)', () {
    expect(inflateBinaryBody(Uint8List.fromList(ascii.encode('<?xml?>'))), isNull);
    expect(inflateBinaryBody(Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3])), isNull);
    expect(inflateBinaryBody(Uint8List(0)), isNull);
    expect(binaryBodyStrings(Uint8List(0)), isEmpty);
  });
}
