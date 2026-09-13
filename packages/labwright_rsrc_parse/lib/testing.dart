/// Fixtures for tests and demos.
library;

import 'dart:typed_data';

/// The smallest RSRC file the parser accepts: a header, an info area listing one empty
/// section per tag in [blocks], and the trailing [name].
Uint8List minimalViBytes({
  String fileType = 'LVIN',
  List<String> blocks = const ['vers', 'FPHb', 'BDHb', 'CONP', 'LIvi'],
  String name = 'demo.vi',
}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  const rsrcMagic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];
  const formatVersion = 3;
  const infoSectionOffset = 32;
  const blockInfoListOffset = 0x34;

  final header = BytesBuilder()..add(rsrcMagic);
  be16(header, formatVersion);
  header
    ..add(fileType.codeUnits)
    ..add('LBVW'.codeUnits);
  be32(header, infoSectionOffset);
  be32(header, 0);
  be32(header, 0x20);
  be32(header, 0);
  final headerBytes = header.toBytes();

  final info = BytesBuilder()..add(headerBytes);
  be32(info, 0);
  be32(info, 0);
  be32(info, 0x20);
  be32(info, blockInfoListOffset);
  be32(info, 0);
  be32(info, blocks.length);
  for (final tag in blocks) {
    info
      ..add(tag.codeUnits)
      ..add(const [0, 0, 0, 0, 0, 0, 0, 0]);
  }
  info
    ..addByte(name.length)
    ..add(name.codeUnits);

  return (BytesBuilder()
        ..add(headerBytes)
        ..add(info.toBytes()))
      .toBytes();
}
