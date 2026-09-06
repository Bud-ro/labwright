import 'dart:io';
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

/// [records] framed with the u32 heap content-length header.
Uint8List heapBody(List<int> records) => u8([0, 0, 0, records.length, ...records]);

/// Big-endian `u16` bytes.
List<int> be16(int value) => [(value >> 8) & 0xff, value & 0xff];

/// Object/group open record: `10 <tag> 02 fe <u16 kind> fd <u16 oid>`.
List<int> open(int kind, int oid, {int tag = 0x19}) => [0x10, tag, 0x02, 0xfe, ...be16(kind), 0xfd, ...be16(oid)];

/// Group close record for [tag].
List<int> close([int tag = 0x19]) => [0x08, tag];

/// Object bounds record `C4 2D 08 <u16 top left bottom right>`.
List<int> bounds(int top, int left, int bottom, int right) => [
  0xc4,
  0x2d,
  0x08,
  ...be16(top),
  ...be16(left),
  ...be16(bottom),
  ...be16(right),
];

/// Child-membership reference `14 19 01 FD <u16 oid>`.
List<int> childRef(int oid) => [0x14, 0x19, 0x01, 0xfd, ...be16(oid)];

/// Label caption record `C4 22 <len> <text>`.
List<int> caption(String text) => [0xc4, 0x22, text.length, ...text.codeUnits];

/// Description/help record `C4 19 <len> <text>` ([HeapRecord.descriptionText]).
List<int> help(String text) => [0xc4, 0x19, text.length, ...text.codeUnits];

/// Enum/ring item table `C4 2E <len> <pascal items>`.
List<int> enum2e(List<String> items) {
  final table = [for (final item in items) ...pascal(item)];
  return [0xc4, 0x2e, table.length, ...table];
}

/// `C6 <id> FF <u16 len> <u32 strlen> <text>` string blob.
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

/// Length-prefixed container attribute record `C5 <id> <u8 len> <payload>`.
List<int> c5(int id, List<int> payload) => [0xc5, id, payload.length, ...payload];

/// One-byte numeric attribute record `24 <id> <u8 value>`.
List<int> attrU8(int id, int value) => [0x24, id, value & 0xff];

/// Two-byte-BE numeric attribute record `44 <id> <u16 value>`.
List<int> attrU16(int id, int value) => [0x44, id, ...be16(value)];

/// Three-byte-BE numeric attribute record `64 <id> <u24 value>`.
List<int> attrU24(int id, int value) => [0x64, id, (value >> 16) & 0xff, ...be16(value)];

/// Four-byte-BE numeric attribute record `84 <id> <u32 value>`.
List<int> attrU32(int id, int value) => [0x84, id, ...be16(value >> 16), ...be16(value)];

/// Whether [entity] is present. When it is not, marks the running test skipped
/// (`'<what> not fetched'`) so the caller can return.
bool corpusOrSkip(FileSystemEntity entity, {String what = 'corpus'}) {
  if (entity.existsSync()) return true;
  markTestSkipped('$what not fetched');
  return false;
}

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
