import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

Uint8List hx(String s) {
  final t = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16)]);
}

Uint8List u8(List<int> b) => Uint8List.fromList(b);

ByteData bd(Uint8List b) => ByteData.sublistView(b);

/// Matches a zero-copy view over exactly [bytes]: same buffer, offset and length.
Matcher viewOf(Uint8List bytes) => predicate<Uint8List>(
  (v) => v.buffer == bytes.buffer && v.offsetInBytes == bytes.offsetInBytes && v.length == bytes.length,
  'a view over the same ${bytes.length} bytes',
);

List<int> pascal(String s) => [s.length, ...s.codeUnits];

ViSection sec(String tag, List<int> bytes) => ViSection(tag: tag, index: 0, dataOffset: 0, bytes: u8(bytes));

DecodedSection dsec(List<int> bytes, {String tag = 'BDEx', bool comp = false}) =>
    DecodedSection(section: sec(tag, bytes), bytes: u8(bytes), wasCompressed: comp);

Uint8List heapBody(List<int> records) => u8([0, 0, 0, records.length, ...records]);

List<int> be16(int value) => [(value >> 8) & 0xff, value & 0xff];

List<int> be32(int value) => [...be16(value >> 16), ...be16(value)];

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

List<int> label(String text) => [text.length, ...text.codeUnits, if (text.length.isEven) 0];

/// A `VCTP` descriptor: length word, flags, [code], [body] and a label when [name] is given.
List<int> descriptor(int code, List<int> body, {String? name, int flags = 0}) {
  final rest = [name == null ? flags : flags | 0x40, code, ...body, if (name != null) ...label(name)];
  return [((2 + rest.length) >> 8) & 0xff, (2 + rest.length) & 0xff, ...rest];
}

List<int> numeric(int code, {String? name}) => descriptor(code, [0], name: name);

Uint8List poolOf(List<List<int>> descriptors, {List<int> topLevel = const []}) => u8([
  0, 0, 0, descriptors.length, //
  for (final d in descriptors) ...d,
  0, topLevel.length,
  for (final i in topLevel) ...[i >> 8, i & 0xff],
]);

/// An RSRC file over [blocks], each tag with its sections' payloads in order, laid out as
/// LabVIEW lays a VI out: the info area holds the header copy, the block list with its count
/// stored one short, the pre-gap, one 20-byte descriptor per section of every block but the
/// last, the 12-byte name-table header carrying the last block's one section as its `secRel`,
/// then the VI name. A tag in [embeddedTags] gets the embedded namespace word.
Uint8List buildRsrc(
  List<({String tag, List<List<int>> sections})> blocks, {
  Set<String> embeddedTags = const {},
  String name = 'fixture.vi',
}) {
  assert(blocks.isEmpty || blocks.last.sections.length == 1, 'the last block has the one section the name table holds');
  final data = BytesBuilder();
  final secRels = <int>[];
  for (final block in blocks) {
    for (final section in block.sections) {
      while (data.length & 3 != 0) {
        data.addByte(0);
      }
      secRels.add(data.length);
      data.add(be32(section.length));
      data.add(section);
    }
  }
  final dataBytes = data.toBytes();
  const blockListRel = 0x34;
  final descriptorsAt = blockListRel + 4 + blocks.length * 12 + 8;
  final described = blocks.isEmpty ? 0 : secRels.length - 1;
  final nameTableAt = descriptorsAt + described * 20;
  final nameAt = nameTableAt + 12;
  final infoSize = nameAt + 1 + name.length;

  Uint8List header() => u8([
    0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a, //
    ...be16(3),
    ...'LVIN'.codeUnits,
    ...'LBVW'.codeUnits,
    ...be32(32 + dataBytes.length),
    ...be32(infoSize),
    ...be32(32),
    ...be32(dataBytes.length),
  ]);

  final info = BytesBuilder()
    ..add(header())
    ..add(be32(0))
    ..add(be32(0))
    ..add(be32(0x20))
    ..add(be32(blockListRel))
    ..add(be32(nameAt))
    ..add(be32(blocks.isEmpty ? 0 : blocks.length - 1));
  var descRel = descriptorsAt - (blockListRel + 8);
  for (final block in blocks) {
    info
      ..add(block.tag.codeUnits)
      ..add(be32(block.sections.length - 1))
      ..add(be32(descRel));
    descRel += block.sections.length * 20;
  }
  info
    ..add(be32(0))
    ..add(be32(embeddedTags.isEmpty ? 0 : 0xFFFFFFFF));
  var section = 0;
  for (final block in blocks.take(described == 0 ? 0 : blocks.length - 1)) {
    for (var i = 0; i < block.sections.length; i++) {
      info
        ..add(be32(0))
        ..add(be32(secRels[section++]))
        ..add(be32(0))
        ..add(be32(0))
        ..add(be32(embeddedTags.contains(block.tag) ? 0 : 0xFFFFFFFF));
    }
  }
  info
    ..add(be32(0))
    ..add(be32(blocks.isEmpty ? 0 : secRels.last))
    ..add(be32(0))
    ..add(pascal(name));
  return u8([...header(), ...dataBytes, ...info.toBytes()]);
}

Uint8List compressedSection(List<int> payload) {
  final z = const ZLibEncoder().encode(payload);
  return u8([...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(), ...z]);
}
