import 'dart:convert';
import 'dart:io';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/md5.g.dart';
import 'snippets.dart';

const Map<String, String> kRfc1321Vectors = {
  '': 'd41d8cd98f00b204e9800998ecf8427e',
  'a': '0cc175b9c0f1b6a831c399e269772661',
  'abc': '900150983cd24fb0d6963f7d28e17f72',
  'message digest': 'f96b697d7cb7938d525a2f31aaf161d0',
  'abcdefghijklmnopqrstuvwxyz': 'c3fcd3d76192e4007dfb496cca67e13b',
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789': 'd174ab98d277d9f5a5611c2c9f419d9f',
  '12345678901234567890123456789012345678901234567890123456789012345678901234567890':
      '57edf4a22be3c955ac49da2e2107b67a',
};
List<String> boundaryMessages() => [
  for (final length in const [54, 55, 56, 57, 63, 64, 65, 119, 120, 128, 191, 192, 1000])
    String.fromCharCodes([for (var index = 0; index < length; index++) 0x61 + index % 26]),
];

void main() {
  test('every RFC 1321 test vector', () {
    for (final MapEntry(key: message, value: digest) in kRfc1321Vectors.entries) {
      expect(
        md5(messageString: message).md5MessageDigestHex,
        digest,
        reason: 'RFC 1321 publishes this digest for a ${message.length}-byte message',
      );
    }
  });

  test("the VI's byte digest is the same value its hexadecimal digest spells", () {
    for (final message in [...kRfc1321Vectors.keys, ...boundaryMessages()]) {
      final result = md5(messageString: message);
      final bytes = latin1.encode(result.md5MessageDigestAscii);
      expect(bytes, hasLength(16), reason: 'a digest is 16 bytes');
      expect(
        [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join(),
        result.md5MessageDigestHex,
        reason: 'over a ${message.length}-byte message',
      );
    }
  });

  test('the padding boundaries each produce a distinct 32-character digest', () {
    final digests = <String>{};
    for (final message in boundaryMessages()) {
      final digest = md5(messageString: message).md5MessageDigestHex;
      expect(digest, matches(RegExp(r'^[0-9a-f]{32}$')), reason: 'over ${message.length} bytes');
      expect(digests.add(digest), isTrue, reason: 'a repeated digest at ${message.length} bytes');
    }
    expect(digests, hasLength(boundaryMessages().length));
  });

  test('the checked-in generated source is exactly what the block diagram lowers to', () {
    final unit = snippetUnit('MD5');
    final result = emitLvLibrary(unit, functionName: 'md5', sourceNote: 'MD5.vi');
    expect(result.refusal, isNull, reason: 'MD5.vi must lower');
    final committed = File(
      '${Directory(_testDir()).path}/generated/md5.g.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      result.source,
      committed,
      reason: 'regenerate with `dart run tool/generate.dart` after changing the emitter',
    );
  });
}

String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
