import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// The reader must be total on adversarial input: every byte string either
/// parses or raises [TdmsFormatException] — never RangeError, OOM, or a hang.
void main() {
  Uint8List validFile() => (TdmsWriter()
        ..writeSegment(
          [
            TdmsChannel(group: 'M', name: 'v', data: const [1.0, 2.0, 3.0], properties: {'unit': 'V', 'n': 3}),
          ],
          fileProperties: {'op': 'loop'},
        ))
      .toBytes();

  test('arbitrary random bytes never crash the reader', () {
    final rng = Random(12345);
    for (var i = 0; i < 3000; i++) {
      final n = rng.nextInt(80);
      final b = Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]);
      try {
        TdmsReader.read(b);
      } on TdmsFormatException {
        // expected for malformed input
      }
    }
  });

  test('bit-flips of a valid file fail cleanly (TdmsFormatException only)', () {
    final valid = validFile();
    final rng = Random(7);
    const flipTrials = 8000;
    var handled = 0;
    for (var i = 0; i < flipTrials; i++) {
      final b = Uint8List.fromList(valid);
      final flips = 1 + rng.nextInt(4);
      for (var f = 0; f < flips; f++) {
        b[rng.nextInt(b.length)] = rng.nextInt(256);
      }
      try {
        TdmsReader.read(b);
      } on TdmsFormatException {/* expected */}
      handled++;
    }
    expect(handled, flipTrials, reason: 'no exception type other than TdmsFormatException escaped');
  });

  test('every truncation of a valid file fails cleanly', () {
    final valid = validFile();
    for (var cut = 0; cut <= valid.length; cut++) {
      try {
        TdmsReader.read(Uint8List.sublistView(valid, 0, cut));
      } on TdmsFormatException {
        // expected for truncated input
      }
    }
  });

  test('valid files still round-trip after hardening', () {
    final f = TdmsReader.read(validFile());
    expect(f.group('M')!.channel('v')!.data, [1.0, 2.0, 3.0]);
    expect(f.properties['op'], 'loop');
  });
}
