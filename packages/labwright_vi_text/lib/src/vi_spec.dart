import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'heap_spec.dart';

/// One section of a VI as the text form holds it; [payload] is the section's inflated bytes.
sealed class SectionSpec {
  const SectionSpec(this.tag, {this.index = 0, this.compressed = false});

  final String tag;

  final int index;

  /// Whether the file stores the section behind the compressed envelope.
  final bool compressed;

  Uint8List get payload;
}

/// A heap section (`FPHb`, `BDHb`) as its records.
final class HeapSection extends SectionSpec {
  const HeapSection(
    super.tag,
    this.records, {
    super.index,
    super.compressed = true,
  });

  final List<HeapSpec> records;

  @override
  Uint8List get payload => encodeHeapSpecs(records);
}

/// A type pool (`VCTP`) as its descriptors and the top-level list.
final class TypePoolSection extends SectionSpec {
  const TypePoolSection(
    this.descriptors, {
    this.topLevel = const [],
    super.index,
    super.compressed = true,
  }) : super('VCTP');

  final List<Uint8List> descriptors;

  final List<int> topLevel;

  @override
  Uint8List get payload => Uint8List.fromList([
    descriptors.length >> 24 & 0xff,
    descriptors.length >> 16 & 0xff,
    descriptors.length >> 8 & 0xff,
    descriptors.length & 0xff,
    for (final descriptor in descriptors) ...descriptor,
    topLevel.length >> 8 & 0xff,
    topLevel.length & 0xff,
    for (final index in topLevel) ...[index >> 8 & 0xff, index & 0xff],
  ]);
}

/// A section carried as its bytes.
final class RawSection extends SectionSpec {
  const RawSection(super.tag, this.bytes, {super.index, super.compressed});

  final Uint8List bytes;

  @override
  Uint8List get payload => bytes;
}

/// A VI as its sections in file order, which [encode] writes as a file.
class ViSpec {
  const ViSpec(this.name, this.sections, {this.fileType = 'LVIN'});

  final String name;

  final String fileType;

  final List<SectionSpec> sections;

  /// The file: each section's payload, deflated where the file stores it compressed, in a
  /// container laid out as LabVIEW lays one out.
  Uint8List encode() => encodeViFile(name, [
    for (final section in sections)
      (
        section.tag,
        section.compressed
            ? deflateHeapPayload(section.payload)
            : section.payload,
      ),
  ], fileType: fileType);
}

List<int> _u16(int value) => [value >> 8 & 0xff, value & 0xff];

List<int> _u32(int value) => [..._u16(value >> 16), ..._u16(value)];

/// An RSRC file over [sections] (tag and stored payload, in file order; a block's sections are
/// the consecutive entries with its tag): the data area four-byte aligned, then the info area
/// with the header copy, the block list with its count stored one short, the pre-gap, one
/// descriptor per section of every block but the last, the name-table header carrying the last
/// block's one section, and [name].
Uint8List encodeViFile(
  String name,
  List<(String, Uint8List)> sections, {
  String fileType = 'LVIN',
}) {
  final blocks = <(String, List<Uint8List>)>[];
  for (final (tag, payload) in sections) {
    if (blocks.isNotEmpty && blocks.last.$1 == tag) {
      blocks.last.$2.add(payload);
    } else {
      blocks.add((tag, [payload]));
    }
  }
  assert(
    blocks.isEmpty || blocks.last.$2.length == 1,
    'the last block has the one section the name table holds',
  );
  final data = BytesBuilder(copy: false);
  final secRels = <int>[];
  for (final (_, payloads) in blocks) {
    for (final payload in payloads) {
      while (data.length & 3 != 0) {
        data.addByte(0);
      }
      secRels.add(data.length);
      data.add(_u32(payload.length));
      data.add(payload);
    }
  }
  final dataBytes = data.takeBytes();
  const blockListRel = 0x34;
  final descriptorsAt = blockListRel + 4 + blocks.length * 12 + 8;
  final described = blocks.isEmpty ? 0 : secRels.length - 1;
  final nameTableAt = descriptorsAt + described * 20;
  final nameAt = nameTableAt + 12;
  final infoSize = nameAt + 1 + name.length;
  Uint8List header() => Uint8List.fromList([
    0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a, //
    ..._u16(3),
    ...fileType.codeUnits,
    ...'LBVW'.codeUnits,
    ..._u32(32 + dataBytes.length),
    ..._u32(infoSize),
    ..._u32(32),
    ..._u32(dataBytes.length),
  ]);
  final info = BytesBuilder(copy: false)
    ..add(header())
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0x20))
    ..add(_u32(blockListRel))
    ..add(_u32(nameAt))
    ..add(_u32(blocks.isEmpty ? 0 : blocks.length - 1));
  var descRel = descriptorsAt - (blockListRel + 8);
  for (final (tag, payloads) in blocks) {
    info
      ..add(tag.codeUnits)
      ..add(_u32(payloads.length - 1))
      ..add(_u32(descRel));
    descRel += payloads.length * 20;
  }
  info
    ..add(_u32(0))
    ..add(_u32(0));
  var section = 0;
  for (final (_, payloads) in blocks.take(
    described == 0 ? 0 : blocks.length - 1,
  )) {
    for (var i = 0; i < payloads.length; i++) {
      info
        ..add(_u32(0))
        ..add(_u32(secRels[section++]))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add(_u32(0xFFFFFFFF));
    }
  }
  info
    ..add(_u32(0))
    ..add(_u32(blocks.isEmpty ? 0 : secRels.last))
    ..add(_u32(0))
    ..add([name.length, ...name.codeUnits]);
  return Uint8List.fromList([...header(), ...dataBytes, ...info.takeBytes()]);
}
