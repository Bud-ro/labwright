/// `DSIM` — data-space image: a raster header followed by the pixels, or by a PNG stream, or
/// by nothing at all.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     zero                       u32      zero
/// 4       2     width                      u16      pixels per row
/// 6       2     height                     u16      rows
/// 8       2     depth                      u16      bits per pixel: 1, 8, 24 or 32
/// 10      12    TODO                       u32[3]   retained; not decoded
/// 22      4     pixelBytes                 i32      width × height × depth / 8 for a raster;
///                                                   negative when the body is a PNG, role TODO
/// 26      4     zero                       u32      zero
/// 30      2     width                      u16      repeats width
/// 32      2     height                     u16      repeats height
/// 34      2     depth                      u16      repeats depth
/// 36      4     zero                       u32      zero
/// 40      6     TODO                       u16[3]   retained; not decoded
/// 46      rest  body                       u8[]     width × height × depth / 8 packed pixel bytes,
///                                                   or a PNG stream at 46 or 48; any bytes after
///                                                   it are retained
/// ```
///
/// [ViDataSpaceImage] is the sealed view over the payload: [ViDataSpaceRaster] holds packed
/// pixels of `depth` bits, [ViDataSpacePng] a PNG stream, [ViDataSpaceHeaderOnly] a 16-byte
/// header with no body. [decodeDataSpaceImage] requires the header's repeated geometry to
/// agree and the body to tile the payload. [rgbIconFromSections] finds the 24-bit raster
/// a VI stores as its picture.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../decode.dart' show DecodedSection;
import 'MNGI_png_image.dart';

const _zero0 = BlockField(0, 4, 'zero', 'u32', 'zero');
const _width = BlockField(4, 2, 'width', 'u16', 'pixels per row');
const _height = BlockField(6, 2, 'height', 'u16', 'rows');
const _depth = BlockField(8, 2, 'depth', 'u16', 'bits per pixel: 1, 8, 24 or 32');
const _todo10 = BlockField.undecoded(10, 12, type: 'u32[3]');
const _pixelBytes = BlockField(
  22,
  4,
  'pixelBytes',
  'i32',
  'width × height × depth / 8 for a raster; negative when the body is a PNG, role TODO',
);
const _zero26 = BlockField(26, 4, 'zero', 'u32', 'zero');
const _width2 = BlockField(30, 2, 'width', 'u16', 'repeats width');
const _height2 = BlockField(32, 2, 'height', 'u16', 'repeats height');
const _depth2 = BlockField(34, 2, 'depth', 'u16', 'repeats depth');
const _zero36 = BlockField(36, 4, 'zero', 'u32', 'zero');
const _todo40 = BlockField.undecoded(40, 6, type: 'u16[3]');
const _body = BlockField(
  46,
  null,
  'body',
  'u8[]',
  'width × height × depth / 8 packed pixel bytes, or a PNG stream at 46 or 48; any bytes after it are retained',
);

const _headerOnlyBytes = 16;

const BlockLayout dsimLayout = [
  _zero0,
  _width,
  _height,
  _depth,
  _todo10,
  _pixelBytes,
  _zero26,
  _width2,
  _height2,
  _depth2,
  _zero36,
  _todo40,
  _body,
];

/// A view over a `DSIM` payload.
sealed class ViDataSpaceImage {
  ViDataSpaceImage._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get width => _view.getUint16(_width.offset);

  int get height => _view.getUint16(_height.offset);

  int get depth => _view.getUint16(_depth.offset);

  /// Bytes after the body, retained verbatim.
  Uint8List get trailer;

  Uint8List serialize() => bytes;

  /// Byte accounting: the header and the body's framing are modelled, the trailer is
  /// retained.
  ViImageAccounting get accounting;
}

/// A `DSIM` whose body is the packed pixels.
final class ViDataSpaceRaster extends ViDataSpaceImage {
  ViDataSpaceRaster._(super.bytes) : super._();

  int get pixelBytes => _view.getInt32(_pixelBytes.offset);

  Uint8List get pixels => Uint8List.sublistView(bytes, _body.offset, _body.offset + pixelBytes);

  @override
  Uint8List get trailer => Uint8List.sublistView(bytes, _body.offset + pixelBytes);

  @override
  ViImageAccounting get accounting =>
      ViImageAccounting(modelBytes: _body.offset + pixelBytes, copiedBytes: trailer.length);
}

/// A `DSIM` whose body is a PNG stream.
final class ViDataSpacePng extends ViDataSpaceImage {
  ViDataSpacePng._(super.bytes, this.pngOffset, this.png) : super._();

  /// Where the PNG signature sits: 46, or 48 when a u16 precedes it.
  final int pngOffset;

  final ViPngStream png;

  @override
  Uint8List get trailer => Uint8List.sublistView(bytes, pngOffset + png.bytes.length);

  @override
  ViImageAccounting get accounting => png.accounting(leadBytes: pngOffset, trailerBytes: trailer.length);
}

/// A 16-byte `DSIM` carrying only the geometry.
final class ViDataSpaceHeaderOnly extends ViDataSpaceImage {
  ViDataSpaceHeaderOnly._(super.bytes) : super._();

  @override
  Uint8List get trailer => Uint8List.sublistView(bytes, bytes.length);

  @override
  ViImageAccounting get accounting => ViImageAccounting(modelBytes: bytes.length, copiedBytes: 0);
}

ViDataSpaceImage decodeDataSpaceImage(Uint8List bytes) {
  assert(
    bytes.length == _headerOnlyBytes || bytes.length >= _body.offset,
    'DSIM is a 16-byte header or a 46-byte header and a body',
  );
  final view = ByteData.sublistView(bytes);
  assert(view.getUint32(_zero0.offset) == 0, 'the first word is zero');
  if (bytes.length == _headerOnlyBytes) return ViDataSpaceHeaderOnly._(bytes);
  assert(
    view.getUint16(_width.offset) == view.getUint16(_width2.offset) &&
        view.getUint16(_height.offset) == view.getUint16(_height2.offset) &&
        view.getUint16(_depth.offset) == view.getUint16(_depth2.offset),
    'the geometry repeats at 30',
  );
  for (final pngAt in [_body.offset, _body.offset + 2]) {
    if (ChunkStreamKind.at(bytes, pngAt) != null) return ViDataSpacePng._(bytes, pngAt, pngStreamAt(bytes, pngAt));
  }
  final pixelBytes = view.getInt32(_pixelBytes.offset);
  assert(
    pixelBytes == view.getUint16(_width.offset) * view.getUint16(_height.offset) * view.getUint16(_depth.offset) ~/ 8,
    'pixelBytes is width × height × depth / 8',
  );
  assert(_body.offset + pixelBytes <= bytes.length, 'the pixels fit the payload');
  return ViDataSpaceRaster._(bytes);
}

/// The first 24-bit raster among the `DSIM` sections, the picture a VI stores of itself.
ViDataSpaceRaster? rgbIconFromSections(Iterable<DecodedSection> sections) {
  for (final section in sections) {
    if (section.tag != 'DSIM') continue;
    if (decodeDataSpaceImage(section.bytes) case ViDataSpaceRaster(depth: 24) && final raster) return raster;
  }
  return null;
}
