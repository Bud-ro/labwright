import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'util.dart';

void main() {
  Uint8List validFile() => write(
    [
      ch('M', 'v', [1, 2, 3], props: {'unit': 'V', 'n': 3}),
    ],
    fileProps: {'op': 'loop'},
  );

  void readTotal(Uint8List b) {
    try {
      TdmsReader.read(b);
    } on TdmsFormatException catch (_) {}
  }

  test('arbitrary random bytes never crash the reader', () {
    final rng = Random(12345);
    for (var i = 0; i < 3000; i++) {
      readTotal(Uint8List.fromList([for (var j = 0, n = rng.nextInt(80); j < n; j++) rng.nextInt(256)]));
    }
  });

  test('bit-flips of a valid file fail cleanly', () {
    final valid = validFile();
    final rng = Random(7);
    for (var i = 0; i < 8000; i++) {
      final b = Uint8List.fromList(valid);
      for (var f = 0, flips = 1 + rng.nextInt(4); f < flips; f++) {
        b[rng.nextInt(b.length)] = rng.nextInt(256);
      }
      readTotal(b);
    }
  });

  test('every truncation of a valid file fails cleanly', () {
    final valid = validFile();
    for (var cut = 0; cut <= valid.length; cut++) {
      readTotal(Uint8List.sublistView(valid, 0, cut));
    }
  });

  test('valid files still round-trip after hardening', () {
    final f = TdmsReader.read(validFile());
    expect(f.group('M')!.channel('v')!.data, [1.0, 2.0, 3.0]);
    expect(f.properties['op'], 'loop');
  });
}
