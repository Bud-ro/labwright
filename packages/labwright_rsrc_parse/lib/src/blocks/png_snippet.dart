/// LabVIEW **VI-snippet PNG** reading: a snippet is an ordinary PNG whose
/// visible raster is LabVIEW's own render of a VI's block diagram, with the
/// complete source `.vi` embedded as a custom `niVI` chunk. Extracting that
/// chunk yields a real RSRC file *and* a reference image of the same VI — a
/// paired render oracle, obtained by pure PNG chunk parsing (no NI software).
///
/// Layout facts, measured over every snippet in the pinned corpus
/// (`rcpacini/LabVIEW-VI-Snippet`, 12/12 files):
/// - the `niVI` chunk payload is the byte-exact `.vi` (starts `RSRC\r\n`);
/// - chunk order is `IHDR · IDAT · niVI · tEXt · IEND`;
/// - the raster carries snippet chrome around the diagram: a header strip
///   (toolbar glyphs + version year) above `y = 25`, and a 1-px dashed frame
///   drawn at `x ∈ {1, width-2}`, `y ∈ {25, height-2}`. The diagram pixels are
///   the interior inside that frame — see [snippetDiagramInterior]. LabVIEW
///   crops the diagram to its drawn ink plus a 2-px margin on each side, at
///   1 diagram unit == 1 pixel.
library;

import 'dart:typed_data';

import 'image_block.dart' show crc32;

/// The 8-byte PNG file signature.
const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// The RSRC magic (`RSRC\r\n`) an embedded `.vi` payload begins with.
const List<int> _rsrcMagic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

/// The custom PNG chunk type LabVIEW stores the source `.vi` under.
const String _niViChunkType = 'niVI';

/// Whether [bytes] begins with the PNG file signature.
bool isPngBytes(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// The embedded source `.vi` of the VI-snippet PNG [png], or null when [png]
/// is not a PNG, carries no `niVI` chunk, the chunk fails its CRC-32, or its
/// payload does not begin with the RSRC magic. The returned bytes are a view
/// into [png] (no copy). Never throws.
Uint8List? extractSnippetVi(Uint8List png) {
  if (!isPngBytes(png)) return null;
  final view = ByteData.sublistView(png);
  var i = _pngSignature.length;
  // [u32 length][4CC type][payload][u32 CRC over type+payload], until IEND.
  while (i + 12 <= png.length) {
    final dataLen = view.getUint32(i);
    final dataStart = i + 8;
    final crcPos = dataStart + dataLen;
    if (crcPos + 4 > png.length) return null;
    final type = String.fromCharCodes(png, i + 4, i + 8);
    if (type == _niViChunkType) {
      if (crc32(png, i + 4, crcPos) != view.getUint32(crcPos)) return null;
      if (dataLen < _rsrcMagic.length) return null;
      for (var k = 0; k < _rsrcMagic.length; k++) {
        if (png[dataStart + k] != _rsrcMagic[k]) return null;
      }
      return Uint8List.sublistView(png, dataStart, crcPos);
    }
    i = crcPos + 4;
    if (type == 'IEND') break;
  }
  return null;
}

/// The snippet chrome's header-strip height: the toolbar glyphs + version-year
/// band above the dashed frame's top line, which sits at `y ==` this value.
/// Measured uniform across every snippet in the pinned corpus.
const int snippetHeaderHeight = 25;

/// The dashed chrome frame's inset from the raster edge on the left, right and
/// bottom sides (the frame lines sit at `x ∈ {1, width-2}`, `y == height-2`).
/// Measured uniform across every snippet in the pinned corpus.
const int snippetFrameInset = 1;

/// The diagram-pixel interior of a [width]×[height] snippet raster: everything
/// inside the 1-px dashed chrome frame ([snippetFrameInset]), excluding the
/// frame line itself and the header strip above it ([snippetHeaderHeight]).
/// Half-open `[left, right) × [top, bottom)`.
({int left, int top, int right, int bottom}) snippetDiagramInterior(
  int width,
  int height,
) => (
  left: snippetFrameInset + 1,
  top: snippetHeaderHeight + 1,
  right: width - 1 - snippetFrameInset,
  bottom: height - 1 - snippetFrameInset,
);
