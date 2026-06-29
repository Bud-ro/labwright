import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a minimal big-endian RSRC (.vi) container with the given resource
/// block tags and a trailing VI name, matching the layout [parseVi] reads.
Uint8List _buildVi({required String fileType, required List<String> blocks, required String name}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  final header = BytesBuilder()
    ..add([0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]); // RSRC\r\n
  be16(header, 3); // format version
  header
    ..add(fileType.codeUnits) // file type (4)
    ..add('LBVW'.codeUnits); // creator (4)
  be32(header, 32); // info section offset (right after this 32-byte header)
  be32(header, 0); // info size (unused by parser)
  be32(header, 0x20); // data offset (unused)
  be32(header, 0); // data size (unused)
  final headerBytes = header.toBytes();

  final info = BytesBuilder()..add(headerBytes); // info section repeats the header
  // sub-header: 5 u32, the 4th = offset to the block-info list (0x34)
  be32(info, 0);
  be32(info, 0);
  be32(info, 0x20);
  be32(info, 0x34);
  be32(info, 0);
  be32(info, blocks.length); // block count
  for (final t in blocks) {
    info
      ..add(t.codeUnits)
      ..add([0, 0, 0, 0, 0, 0, 0, 0]); // two u32 per entry
  }
  info
    ..addByte(name.length) // trailing length-prefixed VI name
    ..add(name.codeUnits);

  return (BytesBuilder()
        ..add(headerBytes)
        ..add(info.toBytes()))
      .toBytes();
}

void main() {
  test('parses header, block inventory, capability flags, and name', () {
    final vi = parseVi(_buildVi(fileType: 'LVIN', blocks: ['CONP', 'BDHb', 'vers'], name: 'demo.vi'));
    expect(vi.isVi, isTrue);
    expect(vi.creator, 'LBVW');
    expect(vi.formatVersion, 3);
    expect(vi.blocks, ['CONP', 'BDHb', 'vers']);
    expect(vi.hasConnectorPane, isTrue);
    expect(vi.hasBlockDiagram, isTrue);
    expect(vi.hasFrontPanel, isFalse);
    expect(vi.hasSubViLinks, isFalse);
    expect(vi.name, 'demo.vi');
  });

  test('detects front panel and sub-VI links', () {
    final vi = parseVi(_buildVi(fileType: 'LVIN', blocks: ['FPHb', 'BDHb', 'CONP', 'LIvi'], name: 'top.vi'));
    expect(vi.hasFrontPanel, isTrue);
    expect(vi.hasSubViLinks, isTrue);
    expect(vi.describe(), contains('sub-VI links'));
  });

  test('rejects non-RSRC bytes', () {
    expect(() => parseVi(Uint8List.fromList(List.filled(64, 0))), throwsA(isA<ViFormatException>()));
  });

  test('rejects truncated files', () {
    expect(() => parseVi(Uint8List.fromList([0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a])), throwsA(isA<ViFormatException>()));
  });
}
