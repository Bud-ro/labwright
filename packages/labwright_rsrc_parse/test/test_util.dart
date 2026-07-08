import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Bytes from compact hex, whitespace ignored: `hx('c4 2d 08')`.
Uint8List hx(String s) {
  final t = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16)]);
}

Uint8List u8(List<int> b) => Uint8List.fromList(b);

/// Pascal string: `[len][ascii]`.
List<int> pascal(String s) => [s.length, ...s.codeUnits];

ViSection sec(String tag, List<int> bytes) => ViSection(tag: tag, index: 0, dataOffset: 0, bytes: u8(bytes));

/// A decoded heap section (default tag BDEx).
DecodedSection dsec(List<int> bytes, {String tag = 'BDEx', bool comp = false}) =>
    DecodedSection(section: sec(tag, bytes), bytes: u8(bytes), wasCompressed: comp);

/// Asserts [probe] never leaks a non-[ViFormatException] over [iters] random buffers of up to [maxLen] bytes.
void expectTotal(int seed, int iters, int maxLen, void Function(Uint8List) probe) {
  final rng = Random(seed);
  for (var i = 0; i < iters; i++) {
    final b = Uint8List.fromList([for (var j = 0, n = rng.nextInt(maxLen); j < n; j++) rng.nextInt(256)]);
    try {
      probe(b);
    } on ViFormatException {
      // acceptable: a clean, catchable rejection
    } catch (e) {
      fail('leaked ${e.runtimeType} on ${b.length} bytes: $e');
    }
  }
}
