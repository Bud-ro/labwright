/// The behavioural proof: the Dart lowered from `crc8.vi`'s block diagram
/// computes the same bytes as an independent CRC-8, over the whole published
/// parameter catalogue.
///
/// Two pins, so neither side can drift alone:
///
/// - [crc8Reference] is checked against the **published check values** — the
///   CRC of `123456789` each catalogued CRC-8 is defined to produce — so the
///   reference is anchored to the algorithms' public definition, not to the
///   VI.
/// - The generated [crc8] is then compared to that reference over every
///   catalogue entry and a spread of messages. Byte-exact agreement is what
///   proves the lowering.
///
/// One ordering difference is visible here and is deliberate: the VI applies
/// its Xor Out **before** the output reflection, where the published model
/// reflects first. The two coincide exactly when the output is not reflected
/// or the Xor Out is zero, which every catalogued CRC-8 satisfies — asserted
/// below so the untested corner cannot be forgotten.
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'generated/crc8.g.dart';
import 'snippets.dart';

/// One published CRC-8 parameter set with the check value its definition
/// fixes: the CRC of the nine ASCII bytes `123456789`.
typedef Crc8Variant = ({String name, int poly, int init, bool refIn, bool refOut, int xorOut, int check});

/// The catalogued CRC-8 algorithms. Names and parameters are the public
/// register-transfer ("Rocksoft") model's; `check` is each algorithm's
/// defined check value.
const List<Crc8Variant> kCrc8Catalogue = [
  (name: 'CRC-8', poly: 0x07, init: 0x00, refIn: false, refOut: false, xorOut: 0x00, check: 0xF4),
  (name: 'CRC-8/CDMA2000', poly: 0x9B, init: 0xFF, refIn: false, refOut: false, xorOut: 0x00, check: 0xDA),
  (name: 'CRC-8/DARC', poly: 0x39, init: 0x00, refIn: true, refOut: true, xorOut: 0x00, check: 0x15),
  (name: 'CRC-8/DVB-S2', poly: 0xD5, init: 0x00, refIn: false, refOut: false, xorOut: 0x00, check: 0xBC),
  (name: 'CRC-8/EBU', poly: 0x1D, init: 0xFF, refIn: true, refOut: true, xorOut: 0x00, check: 0x97),
  (name: 'CRC-8/I-CODE', poly: 0x1D, init: 0xFD, refIn: false, refOut: false, xorOut: 0x00, check: 0x7E),
  (name: 'CRC-8/ITU', poly: 0x07, init: 0x00, refIn: false, refOut: false, xorOut: 0x55, check: 0xA1),
  (name: 'CRC-8/MAXIM', poly: 0x31, init: 0x00, refIn: true, refOut: true, xorOut: 0x00, check: 0xA1),
  (name: 'CRC-8/ROHC', poly: 0x07, init: 0xFF, refIn: true, refOut: true, xorOut: 0x00, check: 0xD0),
  (name: 'CRC-8/WCDMA', poly: 0x9B, init: 0x00, refIn: true, refOut: true, xorOut: 0x00, check: 0x25),
];

/// A bit-at-a-time CRC-8 by the public parameter model: the register starts at
/// `init`, each message byte (reflected first when `refIn`) is folded in and
/// shifted eight times against `poly`, and the result is reflected when
/// `refOut` and finally XORed with `xorOut`.
int crc8Reference(
  List<int> message, {
  required int poly,
  required int init,
  required bool refIn,
  required bool refOut,
  required int xorOut,
}) {
  var register = init & 0xFF;
  for (final byte in message) {
    register ^= refIn ? _reverseBits(byte) : byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      register = register & 0x80 != 0 ? (register << 1 ^ poly) & 0xFF : register << 1 & 0xFF;
    }
  }
  if (refOut) register = _reverseBits(register);
  return register ^ xorOut & 0xFF;
}

int _reverseBits(int byte) {
  var out = 0;
  for (var bit = 0; bit < 8; bit++) {
    out = out << 1 | (byte >> bit) & 1;
  }
  return out;
}

/// The messages every variant is compared over: the empty string, the
/// catalogue's own check string, every single byte value, and a spread of
/// lengths that crosses the loop's boundaries.
List<List<int>> messages() => [
  const <int>[],
  latin1.encode('123456789'),
  for (var byte = 0; byte < 256; byte++) [byte],
  [for (var index = 0; index < 255; index++) (index * 31 + 7) & 0xFF],
  latin1.encode('The quick brown fox jumps over the lazy dog'),
  List<int>.filled(1000, 0xFF),
];

void main() {
  test('the reference CRC-8 reproduces every published check value', () {
    final check = latin1.encode('123456789');
    for (final variant in kCrc8Catalogue) {
      expect(
        crc8Reference(
          check,
          poly: variant.poly,
          init: variant.init,
          refIn: variant.refIn,
          refOut: variant.refOut,
          xorOut: variant.xorOut,
        ),
        variant.check,
        reason: '${variant.name} must produce its defined check value',
      );
    }
  });

  test('no catalogued CRC-8 reflects its output and applies a non-zero Xor Out', () {
    // Where both hold, the VI's order (Xor Out, then reflect) and the
    // published model's (reflect, then Xor Out) would disagree, and this
    // corpus cannot say which LabVIEW's authors intended. The catalogue holds
    // no such variant, so the comparison below is exact everywhere it runs.
    for (final variant in kCrc8Catalogue) {
      expect(variant.refOut && variant.xorOut != 0, isFalse, reason: variant.name);
    }
  });

  test('the code lowered from crc8.vi agrees with the reference byte for byte', () {
    var comparisons = 0;
    for (final variant in kCrc8Catalogue) {
      for (final message in messages()) {
        final expected = crc8Reference(
          message,
          poly: variant.poly,
          init: variant.init,
          refIn: variant.refIn,
          refOut: variant.refOut,
          xorOut: variant.xorOut,
        );
        expect(
          crc8(
            dataIn: latin1.decode(message),
            reflectInputF: variant.refIn,
            init0x00: variant.init,
            xorOut0x00: variant.xorOut,
            reflectOutputF: variant.refOut,
            poly0x07: variant.poly,
          ),
          expected,
          reason: '${variant.name} over a ${message.length}-byte message',
        );
        comparisons++;
      }
    }
    expect(comparisons, kCrc8Catalogue.length * messages().length);
  });

  test('the checked-in generated source is exactly what the block diagram lowers to', () {
    final result = emitLvFunction(
      snippetDiagram('crc8'),
      functionName: 'crc8',
      sourceNote: 'crc8.vi',
    );
    expect(result.refusal, isNull, reason: 'crc8.vi must lower');
    // Compared with newlines normalised: the emitter always writes \n, while a
    // Windows checkout hands the committed file back as \r\n.
    final committed = File(
      '${Directory(_testDir()).path}/generated/crc8.g.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      result.source,
      committed,
      reason: 'regenerate with `dart run tool/generate.dart` after changing the emitter',
    );
  });
}

/// This package's `test/` directory, whichever directory the runner started in.
String _testDir() {
  for (final candidate in const ['test', 'packages/labwright_vi_transpile/test']) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('cannot locate the test directory');
}
