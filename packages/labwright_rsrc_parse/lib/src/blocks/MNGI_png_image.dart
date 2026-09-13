/// `MNGI` — a picture as a bare PNG stream, or occasionally an MNG stream, run to its end
/// chunk.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       8     signature                  u8[8]    89 "PNG" 0d 0a 1a 0a, or 8a "MNG" 0d 0a 1a 0a
/// 8       rest  chunks                     entry[]  chunks to the end chunk
///   +0    4     length                     u32      bytes of data
///   +4    4     type                       4cc      chunk type; IHDR or MHDR first, IEND or MEND
///                                                   last
///   +8    rest  data                       u8[length] chunk data
///   +8    4     crc                        u32      CRC-32 of type and data, after data
/// ```
///
/// [ViPngStream] is a view over a PNG or MNG chunk stream that records where each chunk
/// starts; [ChunkStreamKind] names the two signatures; [decodePngStream] requires the chunks
/// to tile the payload exactly. [ViImageAccounting] measures how much of a stream the model
/// accounts for byte by byte.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../block_layout.dart';

const _signature = BlockField(0, 8, 'signature', 'u8[8]', '89 "PNG" 0d 0a 1a 0a, or 8a "MNG" 0d 0a 1a 0a');
const _chunkLength = BlockField(0, 4, 'length', 'u32', 'bytes of data');
const _chunkType = BlockField(4, 4, 'type', '4cc', 'chunk type; IHDR or MHDR first, IEND or MEND last');
const _chunkData = BlockField(8, null, 'data', 'u8[length]', 'chunk data');
const _chunkCrc = BlockField(8, 4, 'crc', 'u32', 'CRC-32 of type and data, after data');
const _chunks = BlockField(
  8,
  null,
  'chunks',
  'entry[]',
  'chunks to the end chunk',
  entry: [_chunkLength, _chunkType, _chunkData, _chunkCrc],
);

const BlockLayout mngiLayout = [_signature, _chunks];

const _chunkHeaderBytes = 8;

const _chunkCrcBytes = 4;

/// The two chunk-stream signatures a picture block carries.
enum ChunkStreamKind {
  png([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'IEND'),

  mng([0x8a, 0x4d, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'MEND')
  ;

  const ChunkStreamKind(this.signature, this.endChunk);

  final List<int> signature;

  final String endChunk;

  static ChunkStreamKind? at(Uint8List bytes, int offset) {
    for (final kind in values) {
      if (kind.matches(bytes, offset)) return kind;
    }
    return null;
  }

  bool matches(Uint8List bytes, int offset) {
    if (offset < 0 || offset + signature.length > bytes.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }
}

/// A view over a PNG or MNG chunk stream.
class ViPngStream {
  ViPngStream._(this.bytes, this.kind, this._chunkOffsets) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final ChunkStreamKind kind;

  final List<int> _chunkOffsets;

  int get chunkCount => _chunkOffsets.length;

  int chunkLengthAt(int index) => _view.getUint32(_chunkOffsets[index] + _chunkLength.offset);

  String chunkTypeAt(int index) {
    final at = _chunkOffsets[index] + _chunkType.offset;
    return String.fromCharCodes(bytes, at, at + 4);
  }

  Uint8List chunkDataAt(int index) {
    final at = _chunkOffsets[index] + _chunkData.offset;
    return Uint8List.sublistView(bytes, at, at + chunkLengthAt(index));
  }

  bool chunkCrcOkAt(int index) {
    final at = _chunkOffsets[index];
    final crcAt = at + _chunkHeaderBytes + chunkLengthAt(index);
    return crc32(bytes, at + _chunkType.offset, crcAt) == _view.getUint32(crcAt);
  }

  /// Image width from IHDR, or frame width from MHDR.
  int get width => _view.getUint32(_chunkOffsets[0] + _chunkData.offset);

  /// Image height from IHDR, or frame height from MHDR.
  int get height => _view.getUint32(_chunkOffsets[0] + _chunkData.offset + 4);

  Uint8List serialize() => bytes;

  Uint8List _idat() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < chunkCount; i++) {
      if (chunkTypeAt(i) == 'IDAT') b.add(chunkDataAt(i));
    }
    return b.toBytes();
  }

  /// The raster the IDAT chunks inflate to, or null when they do not inflate.
  Uint8List? inflateRaster() => _inflateZlib(_idat());

  /// Whether the inflated raster deflates back to the same bytes; null when it does not inflate.
  bool? rasterRoundTrips() {
    final raster = inflateRaster();
    if (raster == null) return null;
    return _zlibRoundTrips(raster);
  }

  /// How many compressed ancillary chunks (zTXt, iCCP, iTXt) inflate, and how many of those
  /// deflate back to the same bytes.
  ({int count, int ok}) ancillaryRoundTrips() {
    var count = 0, ok = 0;
    for (var i = 0; i < chunkCount; i++) {
      final zStart = _ancillaryZlibStart(chunkTypeAt(i), chunkDataAt(i));
      if (zStart == null) continue;
      final inflated = _inflateZlib(Uint8List.sublistView(chunkDataAt(i), zStart));
      if (inflated == null) continue;
      count++;
      if (_zlibRoundTrips(inflated)) ok++;
    }
    return (count: count, ok: ok);
  }

  /// Byte accounting of the stream: framing, verified CRCs and uncompressed chunk data are
  /// modelled; compressed IDAT and ancillary streams and unverified CRCs are retained opaque.
  ViImageAccounting accounting({int leadBytes = 0, int trailerBytes = 0}) {
    var model = leadBytes + ChunkStreamKind.png.signature.length;
    var copied = trailerBytes;
    var crcVerified = 0;
    var compressedContent = 0;
    var inflatedContent = 0;
    for (var i = 0; i < chunkCount; i++) {
      model += _chunkHeaderBytes;
      if (chunkCrcOkAt(i)) {
        model += _chunkCrcBytes;
        crcVerified++;
      } else {
        copied += _chunkCrcBytes;
      }
      final type = chunkTypeAt(i);
      final data = chunkDataAt(i);
      if (type == 'IDAT') {
        copied += data.length;
        continue;
      }
      final zStart = _ancillaryZlibStart(type, data);
      if (zStart == null) {
        model += data.length;
        continue;
      }
      model += zStart;
      copied += data.length - zStart;
      final inflated = _inflateZlib(Uint8List.sublistView(data, zStart));
      if (inflated != null) {
        compressedContent += data.length - zStart;
        inflatedContent += inflated.length;
      }
    }
    final idat = _idat();
    final raster = _inflateZlib(idat);
    if (raster != null) {
      compressedContent += idat.length;
      inflatedContent += raster.length;
    }
    return ViImageAccounting(
      modelBytes: model,
      copiedBytes: copied,
      chunkCount: chunkCount,
      crcVerified: crcVerified,
      compressedContentBytes: compressedContent,
      inflatedContentBytes: inflatedContent,
    );
  }
}

/// How much of a picture block the model accounts for, byte by byte.
class ViImageAccounting {
  const ViImageAccounting({
    required this.modelBytes,
    required this.copiedBytes,
    this.chunkCount = 0,
    this.crcVerified = 0,
    this.compressedContentBytes = 0,
    this.inflatedContentBytes = 0,
  });

  /// Bytes the model derives (framing, headers, verified CRCs, uncompressed chunk data).
  final int modelBytes;

  /// Bytes retained opaque (compressed streams, unverified CRCs, trailers).
  final int copiedBytes;

  final int chunkCount;

  final int crcVerified;

  /// Compressed bytes whose content inflates.
  final int compressedContentBytes;

  /// Inflated size of that content, all of which is modelled once inflated.
  final int inflatedContentBytes;
}

/// The chunk starts of the stream beginning at [start], or null when it does not tile to
/// its end chunk.
List<int>? pngChunkOffsets(Uint8List bytes, int start, ChunkStreamKind kind) {
  final view = ByteData.sublistView(bytes);
  final offsets = <int>[];
  var at = start + kind.signature.length;
  while (at + _chunkHeaderBytes + _chunkCrcBytes <= bytes.length) {
    final end = at + _chunkHeaderBytes + view.getUint32(at) + _chunkCrcBytes;
    if (end > bytes.length) return null;
    offsets.add(at);
    final type = String.fromCharCodes(bytes, at + _chunkType.offset, at + _chunkType.offset + 4);
    at = end;
    if (type == kind.endChunk) return offsets;
  }
  return null;
}

/// The end of the stream whose chunks start at [chunkOffsets].
int pngStreamEnd(Uint8List bytes, List<int> chunkOffsets) {
  final last = chunkOffsets.last;
  return last + _chunkHeaderBytes + ByteData.sublistView(bytes).getUint32(last) + _chunkCrcBytes;
}

/// The stream at [start] in [bytes], which must carry a PNG or MNG signature there and tile
/// to its end chunk; the view covers exactly the stream.
ViPngStream pngStreamAt(Uint8List bytes, int start) {
  final kind = ChunkStreamKind.at(bytes, start);
  assert(kind != null, 'a PNG or MNG signature at $start');
  final offsets = pngChunkOffsets(bytes, start, kind!);
  assert(offsets != null, 'the chunks tile to the end chunk');
  final end = pngStreamEnd(bytes, offsets!);
  if (start == 0 && end == bytes.length) return ViPngStream._(bytes, kind, offsets);
  return ViPngStream._(Uint8List.sublistView(bytes, start, end), kind, [for (final o in offsets) o - start]);
}

ViPngStream decodePngStream(Uint8List bytes) {
  final stream = pngStreamAt(bytes, 0);
  assert(identical(stream.bytes, bytes), 'the stream ends the payload');
  return stream;
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// The PNG CRC-32 of `bytes[start, end)`.
int crc32(Uint8List bytes, int start, int end) {
  var c = 0xffffffff;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

/// Where the zlib stream begins inside a compressed ancillary chunk, or null for any other
/// chunk type or a malformed one.
int? _ancillaryZlibStart(String type, Uint8List data) {
  switch (type) {
    case 'zTXt' || 'iCCP':
      final nul = data.indexOf(0);
      if (nul < 0 || nul + 2 > data.length) return null;
      return nul + 2;
    case 'iTXt':
      final nul1 = data.indexOf(0);
      if (nul1 < 0 || nul1 + 3 > data.length || data[nul1 + 1] != 1) return null;
      final nul2 = data.indexOf(0, nul1 + 3);
      if (nul2 < 0) return null;
      final nul3 = data.indexOf(0, nul2 + 1);
      if (nul3 < 0 || nul3 + 1 > data.length) return null;
      return nul3 + 1;
    default:
      return null;
  }
}

Uint8List? _inflateZlib(Uint8List z) {
  if (z.isEmpty) return null;
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(z));
  } catch (_) {
    return null;
  }
}

bool _zlibRoundTrips(Uint8List content) {
  final round = _inflateZlib(Uint8List.fromList(const ZLibEncoder().encodeBytes(content)));
  if (round == null || round.length != content.length) return false;
  for (var i = 0; i < content.length; i++) {
    if (round[i] != content[i]) return false;
  }
  return true;
}
