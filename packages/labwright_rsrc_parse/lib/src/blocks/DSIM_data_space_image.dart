/// `DSIM` - Data-Space Image: [ViDataSpaceImage]
///
/// A raster header followed by the pixels, by a PNG stream, or by nothing at all:
/// [ViDataSpaceRaster] holds packed pixels of `depth` bits, [ViDataSpacePng] a PNG stream at
/// 46 or 48, [ViDataSpaceHeaderOnly] a 16-byte header with no body. The header repeats its
/// geometry, which must agree. [rgbIconFromSections] finds the 24-bit raster a VI stores as
/// its picture.
///
/// ```text
/// DSIM:
/// offset  size  field      type   meaning
/// 0       4     zero0      u32    Zero.
/// 4       2     width      u16    Pixels per row.
/// 6       2     height     u16    Rows.
/// 8       2     depth      u16    Bits per pixel: 1, 8, 24 or 32.
/// 10      12    unknown10         Three u32 words; roles TODO.
/// 22      4     pixelBytes i32    width × height × depth / 8; negative for a PNG body, role TODO.
/// 26      4     zero26     u32    Zero.
/// 30      2     width2     u16    Repeats width.
/// 32      2     height2    u16    Repeats height.
/// 34      2     depth2     u16    Repeats depth.
/// 36      4     zero36     u32    Zero.
/// 40      6     unknown40         Three u16 words: 0x00FF, 0xFFFF, then 0 or 0x00FF; roles TODO.
/// 46      rest  body       u8[]   Packed pixels, or a PNG stream at 46 or 48; any bytes after it are
///                                 retained.
/// ViDataSpaceHeaderOnly:
/// offset  size  field     type   meaning
/// 0       4     zero0     u32    Zero.
/// 4       2     width     u16    Pixels per row.
/// 6       2     height    u16    Rows.
/// 8       2     depth     u16    Bits per pixel: 1, 8, 24 or 32.
/// 10      6     unknown10        Three u16 words; roles TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../decode.dart' show DecodedSection;
import 'MNGI_png_image.dart';

sealed class ViDataSpaceImage extends ByteRecord {
  ViDataSpaceImage._(super.bytes, super.layout) {
    assert(_zero0.read(view) == 0, 'the first word is zero');
  }

  factory ViDataSpaceImage(Uint8List bytes) {
    if (bytes.length == ViDataSpaceHeaderOnly.layout.size) return ViDataSpaceHeaderOnly(bytes);
    for (final pngAt in [_body.offset, _body.offset + 2]) {
      if (ChunkStreamKind.at(bytes, pngAt) != null) return ViDataSpacePng(bytes, pngAt);
    }
    return ViDataSpaceRaster(bytes);
  }

  /// Pixels per row.
  int get width => _width.read(view);

  /// Rows.
  int get height => _height.read(view);

  /// Bits per pixel: 1, 8, 24 or 32.
  int get depth => _depth.read(view);

  /// Bytes after the body, retained verbatim.
  Uint8List get trailer;

  /// Byte accounting: the header and the body's framing are modelled, the trailer is
  /// retained.
  ViImageAccounting get accounting;

  void _assertGeometryRepeats() {
    assert(
      width == _width2.read(view) && height == _height2.read(view) && depth == _depth2.read(view),
      'the geometry repeats at 30',
    );
  }

  // dart format off
  static const _zero0 = U32(0); // Zero.
  static const _width = U16(4);
  static const _height = U16(6);
  static const _depth = U16(8);
  static const _unknown10 = Unknown(10, size: 12); // Three u32 words; roles TODO.
  static const _pixelBytes = I32(22); // width × height × depth / 8; negative for a PNG body, role TODO.
  static const _zero26 = U32(26); // Zero.
  static const _width2 = U16(30); // Repeats width.
  static const _height2 = U16(32); // Repeats height.
  static const _depth2 = U16(34); // Repeats depth.
  static const _zero36 = U32(36); // Zero.
  static const _unknown40 = Unknown(40, size: 6); // Three u16 words: 0x00FF, 0xFFFF, then 0 or 0x00FF; roles TODO.
  static const _body = Bytes(46); // Packed pixels, or a PNG stream at 46 or 48; any bytes after it are retained.

  static const layout = ByteLayout([_zero0, _width, _height, _depth, _unknown10, _pixelBytes, _zero26, _width2, _height2, _depth2, _zero36, _unknown40, _body]);
  // dart format on
}

/// A `DSIM` whose body is the packed pixels.
final class ViDataSpaceRaster extends ViDataSpaceImage {
  ViDataSpaceRaster(Uint8List bytes) : super._(bytes, ViDataSpaceImage.layout) {
    _assertGeometryRepeats();
    assert(pixelBytes == width * height * depth ~/ 8, 'pixelBytes is width × height × depth / 8');
    assert(ViDataSpaceImage._body.offset + pixelBytes <= view.lengthInBytes, 'the pixels fit the payload');
  }

  int get pixelBytes => ViDataSpaceImage._pixelBytes.read(view);

  Uint8List get pixels =>
      Uint8List.sublistView(view, ViDataSpaceImage._body.offset, ViDataSpaceImage._body.offset + pixelBytes);

  @override
  Uint8List get trailer => Uint8List.sublistView(view, ViDataSpaceImage._body.offset + pixelBytes);

  @override
  ViImageAccounting get accounting =>
      ViImageAccounting(modelBytes: ViDataSpaceImage._body.offset + pixelBytes, copiedBytes: trailer.length);
}

/// A `DSIM` whose body is a PNG stream.
final class ViDataSpacePng extends ViDataSpaceImage {
  ViDataSpacePng(Uint8List bytes, this.pngOffset)
    : png = pngStreamAt(bytes, pngOffset),
      super._(bytes, ViDataSpaceImage.layout) {
    _assertGeometryRepeats();
  }

  /// Where the PNG signature sits: 46, or 48 when a u16 precedes it.
  final int pngOffset;

  final ViPngStream png;

  @override
  Uint8List get trailer => Uint8List.sublistView(view, pngOffset + png.serialize().length);

  @override
  ViImageAccounting get accounting => png.accounting(leadBytes: pngOffset, trailerBytes: trailer.length);
}

/// A 16-byte `DSIM` carrying only the geometry.
final class ViDataSpaceHeaderOnly extends ViDataSpaceImage {
  ViDataSpaceHeaderOnly(Uint8List bytes) : super._(bytes, layout);

  @override
  Uint8List get trailer => Uint8List.sublistView(view, view.lengthInBytes);

  @override
  ViImageAccounting get accounting => ViImageAccounting(modelBytes: view.lengthInBytes, copiedBytes: 0);

  static const _zero0 = U32(0); // Zero.
  static const _width = U16(4); // Pixels per row.
  static const _height = U16(6); // Rows.
  static const _depth = U16(8); // Bits per pixel: 1, 8, 24 or 32.
  static const _unknown10 = Unknown(10, size: 6); // Three u16 words; roles TODO.

  static const layout = ByteLayout([_zero0, _width, _height, _depth, _unknown10]);
}

/// The first 24-bit raster among the `DSIM` sections, the picture a VI stores of itself.
ViDataSpaceRaster? rgbIconFromSections(Iterable<DecodedSection> sections) {
  for (final section in sections) {
    if (section.tag != 'DSIM') continue;
    if (ViDataSpaceImage(section.bytes) case ViDataSpaceRaster(depth: 24) && final raster) return raster;
  }
  return null;
}
