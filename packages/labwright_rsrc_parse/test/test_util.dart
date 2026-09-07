import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

Uint8List hx(String s) {
  final t = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16)]);
}

Uint8List u8(List<int> b) => Uint8List.fromList(b);

List<int> pascal(String s) => [s.length, ...s.codeUnits];

ViSection sec(String tag, List<int> bytes) => ViSection(tag: tag, index: 0, dataOffset: 0, bytes: u8(bytes));

DecodedSection dsec(List<int> bytes, {String tag = 'BDEx', bool comp = false}) =>
    DecodedSection(section: sec(tag, bytes), bytes: u8(bytes), wasCompressed: comp);

Uint8List heapBody(List<int> records) => u8([0, 0, 0, records.length, ...records]);

List<int> be16(int value) => [(value >> 8) & 0xff, value & 0xff];

List<int> open(int kind, int oid, {int tag = 0x19}) => [0x10, tag, 0x02, 0xfe, ...be16(kind), 0xfd, ...be16(oid)];

List<int> close([int tag = 0x19]) => [0x08, tag];

List<int> bounds(int top, int left, int bottom, int right) => [
  0xc4,
  0x2d,
  0x08,
  ...be16(top),
  ...be16(left),
  ...be16(bottom),
  ...be16(right),
];

List<int> childRef(int oid) => [0x14, 0x19, 0x01, 0xfd, ...be16(oid)];

List<int> caption(String text) => [0xc4, 0x22, text.length, ...text.codeUnits];

List<int> help(String text) => [0xc4, 0x19, text.length, ...text.codeUnits];

List<int> enum2e(List<String> items) {
  final table = [for (final item in items) ...pascal(item)];
  return [0xc4, 0x2e, table.length, ...table];
}

List<int> c6blob(int id, String text) => [
  0xc6,
  id,
  0xff,
  ...be16(4 + text.length),
  0,
  0,
  0,
  text.length,
  ...text.codeUnits,
];

List<int> c5(int id, List<int> payload) => [0xc5, id, payload.length, ...payload];

List<int> attrU8(int id, int value) => [0x24, id, value & 0xff];

List<int> attrU16(int id, int value) => [0x44, id, ...be16(value)];

List<int> attrU24(int id, int value) => [0x64, id, (value >> 16) & 0xff, ...be16(value)];

List<int> attrU32(int id, int value) => [0x84, id, ...be16(value >> 16), ...be16(value)];

void expectTotal(int seed, int iters, int maxLen, void Function(Uint8List) probe) {
  final rng = Random(seed);
  for (var i = 0; i < iters; i++) {
    final b = Uint8List.fromList([for (var j = 0, n = rng.nextInt(maxLen); j < n; j++) rng.nextInt(256)]);
    try {
      probe(b);
    } on ViFormatException catch (_) {
    } catch (e) {
      fail('leaked ${e.runtimeType} on ${b.length} bytes: $e');
    }
  }
}
