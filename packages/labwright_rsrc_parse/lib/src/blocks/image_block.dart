/// Byte-faithful framing for the `.vi` **image blocks** — `MNGI` (a bare PNG
/// stream) and `DSIM` (a data-space colour-icon image: a fixed geometry header
/// wrapping either a PNG stream or a raw raster, optionally trailed by a
/// palette).
///
/// The framing is decoded and re-emitted; the genuinely-opaque interior is
/// retained. A PNG's chunk envelope — the 8-byte signature and every chunk's
/// `[u32 length][4cc type][data][u32 CRC-32]` — is uncompressed and
/// reproducible: the lengths are recomputed from the framed data spans and every
/// CRC-32 is recomputed and checked against the stored value. The compressed
/// chunk data (`IDAT`, and the compressed-text/profile chunks `zTXt`/`iCCP`/
/// `iTXt`) is a DEFLATE stream that is not bit-reproducible, so it is retained as
/// an opaque leaf. The other chunks' data (`IHDR` dimensions, `PLTE`, `tEXt`, …)
/// is uncompressed and retained byte-faithfully under a CRC-verified typed
/// header. A raw `DSIM` raster is `width×height×bytesPerPixel` uncompressed
/// pixels, retained under the decoded geometry header.
///
/// [decodeImageBlock] returns the re-emitted bytes (byte-identical to the input
/// for every framed instance) plus the model/copied byte split: model = the
/// decoded/reproduced framing (signature, chunk length/type/verified-CRC, the
/// geometry header) and the byte-faithful uncompressed interiors; copied = the
/// compressed chunk streams and any undecoded trailer. Null when the payload is
/// not a recognized image form (a non-PNG `MNGI` MNG variant, a truncated
/// header) — the caller then keeps it verbatim.
library;

import 'dart:typed_data';

/// The 8-byte PNG signature (`\x89PNG\r\n\x1a\n`).
const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// PNG chunk types whose data is a DEFLATE stream (or may carry one): retained
/// as an opaque leaf rather than modeled, since NI's/any deflate output is not
/// bit-reproducible. `IDAT` is the pixel stream; `zTXt`/`iCCP` are always
/// compressed; `iTXt` may be (a per-chunk flag), so it is treated opaque too.
const Set<String> _compressedChunkTypes = {'IDAT', 'zTXt', 'iCCP', 'iTXt'};

/// The `DSIM` geometry header length in bytes for the raw-raster form; the
/// PNG-carrying form's header runs up to the embedded signature (46 or 48). The
/// leading `u32` is zero and the `[u16 width][u16 height][u16 depth]` geometry at
/// offset 4 is repeated at offset 30 (both corpus-invariant).
const int _dsimRasterHeaderLen = 46;

/// CRC-32 (ISO-3309, reflected, polynomial `0xEDB88320`) as used by PNG chunk
/// checksums and zlib. Computed with native 64-bit ints masked to 32 bits (an
/// `Int32List` table would truncate the polynomial constant to a negative value).
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

/// CRC-32 over `bytes[start, end)`.
int crc32(Uint8List bytes, int start, int end) {
  var c = 0xffffffff;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

/// Bytes per pixel for a `DSIM` raw raster of the given [depth] (bits), or null
/// when the depth is sub-byte / unmodeled (the section then stays copied).
int? _bytesPerPixel(int depth) => switch (depth) {
  8 => 1,
  16 => 2,
  24 => 3,
  32 => 4,
  _ => null,
};

/// A framed image block: the re-emitted [bytes] plus the model/copied byte split
/// and framing diagnostics. [bytes] equals the decoded payload for every valid
/// instance; [modelBytes] + [copiedBytes] == `bytes.length`.
class ViImageBlock {
  const ViImageBlock({
    required this.bytes,
    required this.modelBytes,
    required this.copiedBytes,
    required this.pngChunks,
    required this.crcVerified,
    required this.isRaster,
  });

  /// The re-emitted payload (recomputed PNG framing + retained interiors).
  final Uint8List bytes;

  /// Bytes emitted from decoded/reproduced framing and byte-faithful
  /// uncompressed interiors.
  final int modelBytes;

  /// Bytes retained verbatim: compressed chunk streams and any undecoded trailer.
  final int copiedBytes;

  /// Decoded PNG chunk count (0 for a raw raster).
  final int pngChunks;

  /// PNG chunks whose recomputed CRC-32 matched the stored value.
  final int crcVerified;

  /// Whether the image body is a raw raster (`DSIM`) rather than a PNG stream.
  final bool isRaster;
}

/// One framed PNG chunk within a source buffer.
class _Chunk {
  const _Chunk({required this.dataLen, required this.type, required this.dataStart, required this.crcOk});
  final int dataLen;
  final String type;
  final int dataStart;
  final bool crcOk;

  /// Total on-disk size: `length(4) + type(4) + data + crc(4)`.
  int get total => 12 + dataLen;
}

/// Whether [bytes] begins with the PNG signature at [offset].
bool _hasSignature(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return false;
  for (var i = 0; i < 8; i++) {
    if (bytes[offset + i] != _pngSignature[i]) return false;
  }
  return true;
}

/// Offset of the PNG signature in [bytes] at/after [from], or -1.
int _findSignature(Uint8List bytes, [int from = 0]) {
  for (var p = from; p + 8 <= bytes.length; p++) {
    if (_hasSignature(bytes, p)) return p;
  }
  return -1;
}

/// Walks the PNG chunk stream in [bytes] from signature [start] to `IEND`,
/// verifying each CRC-32. Returns the chunk list and the offset just past the
/// `IEND` chunk's CRC, or null when the stream is truncated / never reaches
/// `IEND`.
({List<_Chunk> chunks, int end})? _walkPng(Uint8List bytes, int start) {
  final view = ByteData.sublistView(bytes);
  final chunks = <_Chunk>[];
  var i = start + 8;
  while (i + 12 <= bytes.length) {
    final dataLen = view.getUint32(i);
    final dataStart = i + 8;
    final crcPos = dataStart + dataLen;
    if (crcPos + 4 > bytes.length) return null;
    final type = String.fromCharCodes(bytes, i + 4, i + 8);
    final storedCrc = view.getUint32(crcPos);
    final crcOk = crc32(bytes, i + 4, crcPos) == storedCrc;
    chunks.add(_Chunk(dataLen: dataLen, type: type, dataStart: dataStart, crcOk: crcOk));
    i = crcPos + 4;
    if (type == 'IEND') return (chunks: chunks, end: i);
  }
  return null;
}

/// Appends the re-emitted PNG stream `[start, end)` to [out] and accumulates its
/// model/copied split into [acc]. The signature and each chunk's length/type are
/// reproduced; each CRC is recomputed (counted model when it matches the stored
/// value, else the stored bytes are copied); uncompressed chunk data is retained
/// as model, compressed chunk data as copied.
void _emitPng(Uint8List src, int start, List<_Chunk> chunks, BytesBuilder out, _Split acc) {
  out.add(_pngSignature);
  acc.model += 8;
  for (final chunk in chunks) {
    // Fresh framing buffers per chunk: BytesBuilder(copy: false) retains adds by
    // reference, so a reused buffer would be clobbered by the next iteration.
    final len = Uint8List(4);
    ByteData.sublistView(len).setUint32(0, chunk.dataLen);
    out.add(len);
    out.add(Uint8List.sublistView(src, chunk.dataStart - 4, chunk.dataStart)); // type 4cc
    out.add(Uint8List.sublistView(src, chunk.dataStart, chunk.dataStart + chunk.dataLen));
    final crc = Uint8List(4);
    ByteData.sublistView(crc).setUint32(0, crc32(src, chunk.dataStart - 4, chunk.dataStart + chunk.dataLen));
    out.add(crc);
    acc.model += 8; // length + type
    if (chunk.crcOk) {
      acc.model += 4; // reproduced CRC
    } else {
      acc.copied += 4; // stored CRC retained
    }
    if (_compressedChunkTypes.contains(chunk.type)) {
      acc.copied += chunk.dataLen;
    } else {
      acc.model += chunk.dataLen;
    }
  }
}

/// Mutable model/copied accumulator.
class _Split {
  int model = 0;
  int copied = 0;
}

/// Whether a `DSIM` geometry header of at least 40 bytes satisfies the
/// corpus-invariant structure: leading `u32` zero, the `[width][height][depth]`
/// geometry at offset 4 repeated at offset 30, and the `u32`s at 26 and 36 zero.
bool _dsimHeaderValid(Uint8List p) {
  if (p.length < 40) return false;
  final v = ByteData.sublistView(p);
  if (v.getUint32(0) != 0) return false;
  if (v.getUint16(4) != v.getUint16(30)) return false;
  if (v.getUint16(6) != v.getUint16(32)) return false;
  if (v.getUint16(8) != v.getUint16(34)) return false;
  return v.getUint32(26) == 0 && v.getUint32(36) == 0;
}

/// Frames an image [payload] for [tag] (`MNGI` or `DSIM`), returning the
/// re-emitted bytes and model/copied split, or null when the payload is not a
/// recognized image form. See the library doc for the model.
ViImageBlock? decodeImageBlock(String tag, Uint8List payload) {
  return switch (tag) {
    'MNGI' => _decodeMngi(payload),
    'DSIM' => _decodeDsim(payload),
    _ => null,
  };
}

/// `MNGI`: a bare PNG stream at offset 0 running to `IEND` at EOF. Null for the
/// rare MNG variant (no PNG signature) or a trailing-bytes mismatch.
ViImageBlock? _decodeMngi(Uint8List payload) {
  if (!_hasSignature(payload, 0)) return null;
  final walk = _walkPng(payload, 0);
  if (walk == null || walk.end != payload.length) return null;
  final acc = _Split();
  final out = BytesBuilder(copy: false);
  _emitPng(payload, 0, walk.chunks, out, acc);
  final crcVerified = walk.chunks.where((c) => c.crcOk).length;
  return ViImageBlock(
    bytes: out.toBytes(),
    modelBytes: acc.model,
    copiedBytes: acc.copied,
    pngChunks: walk.chunks.length,
    crcVerified: crcVerified,
    isRaster: false,
  );
}

/// `DSIM`: a geometry header wrapping a PNG stream or a raw raster, optionally
/// trailed by a palette. Null when the header structure is not corpus-valid or
/// the body is neither a framed PNG nor a raster that tiles the payload.
ViImageBlock? _decodeDsim(Uint8List payload) {
  if (!_dsimHeaderValid(payload)) return null;
  final signatureAt = _findSignature(payload);
  return signatureAt >= 0 ? _decodeDsimPng(payload, signatureAt) : _decodeDsimRaster(payload);
}

/// `DSIM` carrying a PNG: header (retained model) + framed PNG + trailer (copied).
ViImageBlock? _decodeDsimPng(Uint8List payload, int signatureAt) {
  final walk = _walkPng(payload, signatureAt);
  if (walk == null) return null;
  final acc = _Split();
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(payload, 0, signatureAt));
  acc.model += signatureAt; // geometry header
  _emitPng(payload, signatureAt, walk.chunks, out, acc);
  final trailer = payload.length - walk.end;
  if (trailer > 0) {
    out.add(Uint8List.sublistView(payload, walk.end));
    acc.copied += trailer; // undecoded palette trailer
  }
  return ViImageBlock(
    bytes: out.toBytes(),
    modelBytes: acc.model,
    copiedBytes: acc.copied,
    pngChunks: walk.chunks.length,
    crcVerified: walk.chunks.where((c) => c.crcOk).length,
    isRaster: false,
  );
}

/// `DSIM` carrying a raw raster: 46-byte geometry header + `width×height×bpp`
/// pixels (both model) + trailer (copied). The `u32` at offset 22 equals the
/// pixel byte count (corpus-invariant) and gates the framing.
ViImageBlock? _decodeDsimRaster(Uint8List payload) {
  if (payload.length < _dsimRasterHeaderLen) return null;
  final v = ByteData.sublistView(payload);
  final width = v.getUint16(4);
  final height = v.getUint16(6);
  final depth = v.getUint16(8);
  final bpp = _bytesPerPixel(depth);
  if (bpp == null) return null;
  final pixelBytes = width * height * bpp;
  if (v.getUint32(22) != pixelBytes) return null;
  final bodyEnd = _dsimRasterHeaderLen + pixelBytes;
  if (bodyEnd > payload.length) return null;
  final trailer = payload.length - bodyEnd;
  return ViImageBlock(
    bytes: Uint8List.fromList(payload), // header + pixels + trailer, all retained
    modelBytes: bodyEnd, // geometry header + pixel raster
    copiedBytes: trailer,
    pngChunks: 0,
    crcVerified: 0,
    isRaster: true,
  );
}
