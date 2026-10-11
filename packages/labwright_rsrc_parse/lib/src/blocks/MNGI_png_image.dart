/// `MNGI` - PNG Image: [ViPngStream]
///
/// A picture as a bare PNG stream, or occasionally an MNG stream, run to its end chunk;
/// [ChunkStreamKind] names the two signatures and [ViImageAccounting] measures how much of a
/// stream the model accounts for byte by byte.
///
/// ```text
/// offset      size   field     type       meaning
/// 0           8      signature u8[8]      89 "PNG" 0d 0a 1a 0a, or 8a "MNG" 0d 0a 1a 0a.
/// 8           rest   chunks    PngChunk[] Chunks to the end chunk.
///   +0        4      length    u32        Bytes of data.
///   +4        4      type      4cc        Chunk type; IHDR or MHDR first, IEND or MEND last.
///   +8        length data      u8[length]
///   +8+length 4      crc       u32        CRC-32 of type and data, after data.
/// ```
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../byte_layout.dart';
import '../byte_record.dart';

/// One PNG or MNG chunk.
abstract final class PngChunk {
  static const length = U32(0); // Bytes of data.
  static const type = FourCc(4); // Chunk type; IHDR or MHDR first, IEND or MEND last.
  static const data = Bytes(8, count: length);
  static const crc = U32(8); // CRC-32 of type and data, after data.

  static const layout = ByteLayout([length, type, data, crc]);
}

/// The two chunk-stream signatures a picture block carries.
enum ChunkStreamKind {
  png([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'IEND'),

  mng([0x8a, 0x4d, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'MEND');

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

final class ViPngStream extends ByteRecord {
  ViPngStream(Uint8List bytes) : super(bytes, layout) {
    final found = ChunkStreamKind.at(bytes, 0);
    assert(found != null, 'a PNG or MNG signature');
    kind = found!;
    final offsets = pngChunkOffsets(bytes, 0, kind);
    assert(offsets != null, 'the chunks tile to the end chunk');
    _chunkOffsets = offsets!;
    assert(pngStreamEnd(bytes, _chunkOffsets) == bytes.length, 'the stream ends the payload');
    assert(
      (chunkTypeAt(0) == 'IHDR' || chunkTypeAt(0) == 'MHDR') && chunkLengthAt(0) >= 8,
      'the first chunk is a header with a width and a height',
    );
  }

  late final ChunkStreamKind kind;

  int get chunkCount => _chunkOffsets.length;

  int chunkLengthAt(int index) => view.getUint32(_chunkOffsets[index] + PngChunk.length.offset);

  String chunkTypeAt(int index) {
    final at = _chunkOffsets[index] + PngChunk.type.offset;
    return String.fromCharCodes(Uint8List.sublistView(view, at, at + PngChunk.type.size));
  }

  Uint8List chunkDataAt(int index) {
    final at = _chunkOffsets[index] + PngChunk.data.offset;
    return Uint8List.sublistView(view, at, at + chunkLengthAt(index));
  }

  bool chunkCrcOkAt(int index) {
    final at = _chunkOffsets[index];
    final crcAt = at + PngChunk.data.offset + chunkLengthAt(index);
    return crc32(Uint8List.sublistView(view), at + PngChunk.type.offset, crcAt) == view.getUint32(crcAt);
  }

  /// Image width from IHDR, or frame width from MHDR.
  int get width => view.getUint32(_chunkOffsets[0] + PngChunk.data.offset);

  /// Image height from IHDR, or frame height from MHDR.
  int get height => view.getUint32(_chunkOffsets[0] + PngChunk.data.offset + 4);

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
      model += PngChunk.data.offset;
      if (chunkCrcOkAt(i)) {
        model += PngChunk.crc.size;
        crcVerified++;
      } else {
        copied += PngChunk.crc.size;
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

  late final List<int> _chunkOffsets;

  Uint8List _idat() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < chunkCount; i++) {
      if (chunkTypeAt(i) == 'IDAT') b.add(chunkDataAt(i));
    }
    return b.toBytes();
  }

  static const _signature = Bytes(0, size: 8); // 89 "PNG" 0d 0a 1a 0a, or 8a "MNG" 0d 0a 1a 0a.
  static const _chunks = Entries(8, PngChunk.layout); // Chunks to the end chunk.

  static const layout = ByteLayout([_signature, _chunks]);
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
  while (at + PngChunk.data.offset + PngChunk.crc.size <= bytes.length) {
    final end = at + PngChunk.data.offset + view.getUint32(at) + PngChunk.crc.size;
    if (end > bytes.length) return null;
    offsets.add(at);
    final type = String.fromCharCodes(bytes, at + PngChunk.type.offset, at + PngChunk.type.end);
    at = end;
    if (type == kind.endChunk) return offsets;
  }
  return null;
}

/// The end of the stream whose chunks start at [chunkOffsets].
int pngStreamEnd(Uint8List bytes, List<int> chunkOffsets) {
  final last = chunkOffsets.last;
  return last + PngChunk.data.offset + ByteData.sublistView(bytes).getUint32(last) + PngChunk.crc.size;
}

/// The stream at [start] in [bytes], which must carry a PNG or MNG signature there and tile
/// to its end chunk; the view covers exactly the stream.
ViPngStream pngStreamAt(Uint8List bytes, int start) {
  final kind = ChunkStreamKind.at(bytes, start);
  assert(kind != null, 'a PNG or MNG signature at $start');
  final offsets = pngChunkOffsets(bytes, start, kind!);
  assert(offsets != null, 'the chunks tile to the end chunk');
  return ViPngStream(Uint8List.sublistView(bytes, start, pngStreamEnd(bytes, offsets!)));
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
