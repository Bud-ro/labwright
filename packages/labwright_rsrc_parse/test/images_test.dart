import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

final Uint8List _png1x1 = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

DecodedSection _section(String tag, List<int> body) {
  final bytes = Uint8List.fromList(body);
  return DecodedSection(
    section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: bytes),
    bytes: bytes,
    wasCompressed: false,
  );
}

Uint8List _dsimHeader(int pngLength) =>
    (ByteData(46)
          ..setUint16(4, 1)
          ..setUint16(6, 1)
          ..setUint16(8, 24)
          ..setInt32(22, pngLength)
          ..setUint16(30, 1)
          ..setUint16(32, 1)
          ..setUint16(34, 24))
        .buffer
        .asUint8List();

void main() {
  test('viImagesOf takes the PNG a DSIM carries after its raster header and a bare MNGI PNG', () {
    final images = viImagesOf([
      _section('DSIM', [..._dsimHeader(-1), ..._png1x1, 0xaa]),
      _section('DSIM', [..._dsimHeader(3), 0, 0, 0]),
      _section('MNGI', _png1x1),
      _section('vers', const [1, 2, 3, 4]),
    ]);
    expect([for (final png in images.pngs) (png.tag, png.width, png.height)], [('DSIM', 1, 1), ('MNGI', 1, 1)]);
    for (final png in images.pngs) {
      expect(png.bytes, _png1x1);
    }
    expect((images.icons.length, images.rasters.length, images.count), (0, 0, 2));
  });

  test('viImagesOf decodes legacy icons deepest first and ignores other payloads', () {
    final images = viImagesOf([
      _section('ICON', List<int>.filled(128, 0xff)),
      _section('icl4', List<int>.filled(512, 0x11)),
      _section('icl8', List<int>.filled(1024, 7)),
      _section('icl8', List<int>.filled(10, 7)),
      _section('vers', const [1, 2, 3, 4]),
    ]);
    expect(images.icons.map((i) => i.depth), [LegacyIconDepth.eightBit, LegacyIconDepth.fourBit, LegacyIconDepth.mono]);
    expect(images.bestIcon?.depth, LegacyIconDepth.eightBit);
    expect(
      viImagesOf([
        _section('vers', const [1, 2, 3, 4]),
      ]).isEmpty,
      isTrue,
    );
  });
}
