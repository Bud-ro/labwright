/// Byte-faithful framing for the `.vi` **image blocks** — `MNGI` (a bare PNG
/// stream) and `DSIM` (a data-space colour-icon image: a fixed geometry header
/// wrapping either a PNG stream or a raw raster, optionally trailed by a
/// palette).
///
/// The framing is decoded and re-emitted. A PNG's chunk envelope — the 8-byte
/// signature and every chunk's `[u32 length][4cc type][data][u32 CRC-32]` — is
/// uncompressed and reproducible: the lengths are recomputed from the framed
/// data spans and every CRC-32 is recomputed and checked against the stored
/// value. The `IDAT` pixel stream and the compressed-text/profile chunks
/// (`zTXt`/`iCCP`/compressed `iTXt`) carry DEFLATE streams whose *stored* bytes
/// are not bit-reproducible, so at the byte level those zlib streams are copied
/// verbatim; an ancillary chunk's uncompressed prefix (its keyword/name +
/// method byte) and an uncompressed `iTXt`'s whole data are reproduced (model).
/// The other chunks' data (`IHDR` dimensions, `PLTE`, `tEXt`, …) is uncompressed
/// and retained byte-faithfully under a CRC-verified typed header. A raw `DSIM`
/// raster is `width×height×bytesPerPixel` uncompressed pixels, retained under the
/// decoded geometry header.
///
/// **Content level.** The `IDAT` chunks of a PNG hold one zlib stream split
/// across consecutive chunks; concatenated and inflated ([inflateImageRaster])
/// they yield the raw raster — per-scanline `[filter byte][filtered pixels]`,
/// sized from the `IHDR` geometry. Each compressed ancillary chunk carries its
/// own zlib stream after its prefix. Every such stream is inflated and its
/// inflated content modeled: retained as a typed leaf and re-deflated as a
/// standard RFC-1950 zlib stream, it reproduces the content exactly
/// ([imageRasterRoundTrips] proves the raster round-trip;
/// [imageAncillaryRoundTrips] proves the ancillary streams). The content
/// scoreboard counts the inflated content in place of the compressed stored
/// bytes — the same inflated-content reframe the container applies to its zlib
/// heap sections, one level deeper.
///
/// [decodeImageBlock] returns the re-emitted bytes (byte-identical to the input
/// for every framed instance) plus the byte-level model/copied split (model =
/// the reproduced framing, uncompressed interiors, and ancillary prefixes;
/// copied = the compressed zlib streams and any undecoded trailer) AND the
/// content-level split (the inflated raster + inflated ancillary content,
/// counted as content-model, replacing the compressed stored bytes). Null when
/// the payload is not a recognized image form (a non-PNG `MNGI` MNG variant, a
/// truncated header) — the caller then keeps it verbatim.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The 8-byte PNG signature (`\x89PNG\r\n\x1a\n`).
const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// The compressed ANCILLARY PNG chunk types — `zTXt`/`iCCP` always carry a zlib
/// stream, `iTXt` when its per-chunk compression flag is 1. Each is a
/// `[keyword/name][0]…[method]` prefix followed by a zlib stream: the prefix is
/// uncompressed and reproduced (model), the zlib stream's *stored* bytes are
/// copied at the byte level (NI's/any deflate output is not bit-reproducible)
/// and inflated to content at the content level (see [_ancillaryZlibStart]) —
/// the same nested-deflate reframe [inflateImageRaster] applies to the `IDAT`
/// pixel stream, one level deeper. An `iTXt` with compression flag 0 carries no
/// zlib stream, so its data is uncompressed and modeled byte-faithfully.
const Set<String> _ancillaryCompressedTypes = {'zTXt', 'iCCP', 'iTXt'};

/// The byte offset within an ancillary chunk's [data] where its zlib stream
/// begins — the length of the uncompressed prefix (keyword/name + separators +
/// method byte) — or -1 when the chunk carries no zlib stream (an `iTXt` with
/// compression flag 0, or a prefix truncated before the stream).
///  * `zTXt`/`iCCP`: `[keyword/name][0][method(1)][zlib]`.
///  * `iTXt`: `[keyword][0][compFlag(1)][compMethod(1)][langtag][0][transKw][0]
///    [text]`, whose `text` is a zlib stream only when `compFlag == 1`.
int _ancillaryZlibStart(String type, Uint8List data) {
  switch (type) {
    case 'zTXt':
    case 'iCCP':
      final nul = data.indexOf(0);
      if (nul < 0 || nul + 2 > data.length) return -1;
      return nul + 2;
    case 'iTXt':
      final nul1 = data.indexOf(0);
      if (nul1 < 0 || nul1 + 3 > data.length) return -1;
      if (data[nul1 + 1] != 1) return -1; // compression flag 0 — uncompressed
      final nul2 = _indexOfFrom(data, 0, nul1 + 3);
      if (nul2 < 0) return -1;
      final nul3 = _indexOfFrom(data, 0, nul2 + 1);
      if (nul3 < 0 || nul3 + 1 > data.length) return -1;
      return nul3 + 1;
    default:
      return -1;
  }
}

/// First index of [value] in [b] at/after [from], or -1.
int _indexOfFrom(Uint8List b, int value, int from) {
  for (var i = from; i < b.length; i++) {
    if (b[i] == value) return i;
  }
  return -1;
}

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
    this.compressedContentBytes = 0,
    this.inflatedContentBytes = 0,
    this.inflatedModelBytes = 0,
    this.inflatedCopiedBytes = 0,
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

  /// Compressed `IDAT` stored bytes swapped out at the content level (the pixel
  /// zlib stream that inflates to [inflatedContentBytes]); 0 when the payload
  /// carries no inflatable `IDAT` (a raw raster, a non-PNG body, or an `IDAT`
  /// stream that fails to inflate — which then stays counted in [copiedBytes]).
  final int compressedContentBytes;

  /// Inflated raster size that replaces [compressedContentBytes] in the content
  /// total (`inflatedModelBytes + inflatedCopiedBytes`).
  final int inflatedContentBytes;

  /// Inflated raster bytes modeled as content — the raster leaf that re-deflates
  /// to a standard zlib stream carrying the same pixel content
  /// ([imageRasterRoundTrips]).
  final int inflatedModelBytes;

  /// Inflated raster bytes not modeled as content (0 for a raster that inflates
  /// cleanly).
  final int inflatedCopiedBytes;
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

/// Concatenates the `IDAT` chunk data of [chunks] in [src] into one buffer. A
/// PNG stores its pixel zlib stream split across consecutive `IDAT` chunks, so
/// the stream is the concatenation of their data in order.
Uint8List _gatherIdat(Uint8List src, List<_Chunk> chunks) {
  final b = BytesBuilder(copy: false);
  for (final c in chunks) {
    if (c.type == 'IDAT') b.add(Uint8List.sublistView(src, c.dataStart, c.dataStart + c.dataLen));
  }
  return b.toBytes();
}

/// Inflates the RFC-1950 zlib stream [z], or null on any error / empty input.
Uint8List? _inflateZlib(Uint8List z) {
  if (z.isEmpty) return null;
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(z));
  } catch (_) {
    return null;
  }
}

/// The inflated raster of the PNG carried by an image [payload] for [tag]
/// (`DSIM`/`MNGI`): the concatenated `IDAT` zlib stream inflated to per-scanline
/// `[filter byte][filtered pixels]`. Null when [payload] carries no PNG (a raw
/// `DSIM` raster, a non-PNG `MNGI`), the stream is truncated before `IEND`, or
/// the `IDAT` fails to inflate. Never throws.
Uint8List? inflateImageRaster(String tag, Uint8List payload) {
  final start = switch (tag) {
    'MNGI' => _hasSignature(payload, 0) ? 0 : -1,
    'DSIM' => _dsimHeaderValid(payload) ? _findSignature(payload) : -1,
    _ => -1,
  };
  if (start < 0) return null;
  final walk = _walkPng(payload, start);
  if (walk == null) return null;
  return _inflateZlib(_gatherIdat(payload, walk.chunks));
}

/// Whether the PNG raster in [payload] survives a standard-zlib round-trip:
/// `inflate(deflate(inflate(IDAT))) == inflate(IDAT)`, byte-for-byte. Returns
/// null when [payload] carries no inflatable PNG raster (nothing to prove) — the
/// "compatible zlib" evidence that the raster content is reproducible through a
/// standard RFC-1950 stream without loading LabVIEW. Never throws.
bool? imageRasterRoundTrips(String tag, Uint8List payload) {
  final raster = inflateImageRaster(tag, payload);
  if (raster == null) return null;
  final round = _inflateZlib(Uint8List.fromList(const ZLibEncoder().encodeBytes(raster)));
  if (round == null || round.length != raster.length) return false;
  for (var i = 0; i < raster.length; i++) {
    if (round[i] != raster[i]) return false;
  }
  return true;
}

/// Round-trip census over the compressed ANCILLARY streams (`iCCP`/`zTXt`/
/// compressed `iTXt`) of the PNG in [payload]: `count` is how many such streams
/// inflate, `ok` how many also survive a standard-zlib round-trip
/// (`inflate(deflate(inflate(stream))) == inflate(stream)`). Both zero when the
/// payload carries no inflatable ancillary stream. The "compatible zlib"
/// evidence for the ancillary content, parallel to [imageRasterRoundTrips] for
/// the raster. Never throws.
({int count, int ok}) imageAncillaryRoundTrips(String tag, Uint8List payload) {
  final start = switch (tag) {
    'MNGI' => _hasSignature(payload, 0) ? 0 : -1,
    'DSIM' => _dsimHeaderValid(payload) ? _findSignature(payload) : -1,
    _ => -1,
  };
  if (start < 0) return (count: 0, ok: 0);
  final walk = _walkPng(payload, start);
  if (walk == null) return (count: 0, ok: 0);
  var count = 0, ok = 0;
  for (final c in walk.chunks) {
    if (!_ancillaryCompressedTypes.contains(c.type)) continue;
    final data = Uint8List.sublistView(payload, c.dataStart, c.dataStart + c.dataLen);
    final zStart = _ancillaryZlibStart(c.type, data);
    if (zStart < 0) continue;
    final infl = _inflateZlib(Uint8List.sublistView(data, zStart));
    if (infl == null) continue;
    count++;
    final round = _inflateZlib(Uint8List.fromList(const ZLibEncoder().encodeBytes(infl)));
    if (round != null && round.length == infl.length && _bytesEqual(round, infl)) ok++;
  }
  return (count: count, ok: ok);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Content-level split for the nested-deflate streams of the PNG carried by
/// [chunks] in [src]: the compressed stored size
/// ([ViImageBlock.compressedContentBytes]) and the inflated size it is swapped
/// for ([ViImageBlock.inflatedContentBytes]), summed over the `IDAT` pixel
/// stream and every compressed ancillary chunk (`iCCP`/`zTXt`/compressed
/// `iTXt`). A stream that fails to inflate contributes nothing (its compressed
/// bytes stay copied).
({int compressed, int inflated}) _pngNestedContent(Uint8List src, List<_Chunk> chunks) {
  var compressed = 0, inflated = 0;
  // IDAT pixel stream: the concatenation of the IDAT chunks' data.
  var idatCompressed = 0;
  for (final c in chunks) {
    if (c.type == 'IDAT') idatCompressed += c.dataLen;
  }
  final raster = _inflateZlib(_gatherIdat(src, chunks));
  if (raster != null) {
    compressed += idatCompressed;
    inflated += raster.length;
  }
  // Compressed ancillary chunks: each carries one zlib stream after its prefix.
  for (final c in chunks) {
    if (!_ancillaryCompressedTypes.contains(c.type)) continue;
    final data = Uint8List.sublistView(src, c.dataStart, c.dataStart + c.dataLen);
    final zStart = _ancillaryZlibStart(c.type, data);
    if (zStart < 0) continue; // uncompressed iTXt — no zlib stream
    final infl = _inflateZlib(Uint8List.sublistView(data, zStart));
    if (infl == null) continue;
    compressed += data.length - zStart;
    inflated += infl.length;
  }
  return (compressed: compressed, inflated: inflated);
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
    if (chunk.type == 'IDAT') {
      acc.copied += chunk.dataLen; // pixel zlib stream, no uncompressed prefix
    } else if (_ancillaryCompressedTypes.contains(chunk.type)) {
      // An ancillary chunk splits into an uncompressed prefix (model) and a zlib
      // stream (copied); an uncompressed iTXt (no stream) is modeled whole.
      final data = Uint8List.sublistView(src, chunk.dataStart, chunk.dataStart + chunk.dataLen);
      final zStart = _ancillaryZlibStart(chunk.type, data);
      if (zStart < 0) {
        acc.model += chunk.dataLen;
      } else {
        acc.model += zStart;
        acc.copied += chunk.dataLen - zStart;
      }
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
  final content = _pngNestedContent(payload, walk.chunks);
  return ViImageBlock(
    bytes: out.toBytes(),
    modelBytes: acc.model,
    copiedBytes: acc.copied,
    pngChunks: walk.chunks.length,
    crcVerified: crcVerified,
    isRaster: false,
    compressedContentBytes: content.compressed,
    inflatedContentBytes: content.inflated,
    inflatedModelBytes: content.inflated,
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
  final content = _pngNestedContent(payload, walk.chunks);
  return ViImageBlock(
    bytes: out.toBytes(),
    modelBytes: acc.model,
    copiedBytes: acc.copied,
    pngChunks: walk.chunks.length,
    crcVerified: walk.chunks.where((c) => c.crcOk).length,
    isRaster: false,
    compressedContentBytes: content.compressed,
    inflatedContentBytes: content.inflated,
    inflatedModelBytes: content.inflated,
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
