/// VI snippets: PNG images whose `niVI` chunk holds a complete VI.
library;

import 'dart:typed_data';

import 'blocks/MNGI_png_image.dart' show crc32;

const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

const List<int> _rsrcMagic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

const String _niViChunkType = 'niVI';

/// Whether the bytes start with the PNG signature.
bool isPngBytes(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// The VI inside the PNG's `niVI` chunk (a view), or null when there is no such chunk, its
/// CRC does not match, or it does not start with the RSRC magic.
Uint8List? extractSnippetVi(Uint8List png) {
  if (!isPngBytes(png)) return null;
  final view = ByteData.sublistView(png);
  var i = _pngSignature.length;
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

/// Height of the title band LabVIEW paints above a snippet's diagram.
const int snippetHeaderHeight = 25;

/// Width of the frame LabVIEW paints around a snippet's diagram.
const int snippetFrameInset = 1;

/// The pixel rectangle inside a snippet's frame and title band that holds the diagram.
({int left, int top, int right, int bottom}) snippetDiagramInterior(
  int width,
  int height,
) => (
  left: snippetFrameInset + 1,
  top: snippetHeaderHeight + 1,
  right: width - 1 - snippetFrameInset,
  bottom: height - 1 - snippetFrameInset,
);
