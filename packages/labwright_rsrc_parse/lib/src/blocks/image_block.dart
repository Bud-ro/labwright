import 'dart:typed_data';

import 'package:archive/archive.dart';

const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

const Set<String> _ancillaryCompressedTypes = {'zTXt', 'iCCP', 'iTXt'};

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
      if (data[nul1 + 1] != 1) return -1;
      final nul2 = _indexOfFrom(data, 0, nul1 + 3);
      if (nul2 < 0) return -1;
      final nul3 = _indexOfFrom(data, 0, nul2 + 1);
      if (nul3 < 0 || nul3 + 1 > data.length) return -1;
      return nul3 + 1;
    default:
      return -1;
  }
}

int _indexOfFrom(Uint8List b, int value, int from) {
  for (var i = from; i < b.length; i++) {
    if (b[i] == value) return i;
  }
  return -1;
}

const int _dsimRasterHeaderLen = 46;

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

int crc32(Uint8List bytes, int start, int end) {
  var c = 0xffffffff;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

int? _bytesPerPixel(int depth) => switch (depth) {
  8 => 1,
  16 => 2,
  24 => 3,
  32 => 4,
  _ => null,
};

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

  final Uint8List bytes;

  final int modelBytes;

  final int copiedBytes;

  final int pngChunks;

  final int crcVerified;

  final bool isRaster;

  final int compressedContentBytes;

  final int inflatedContentBytes;

  final int inflatedModelBytes;

  final int inflatedCopiedBytes;
}

class _Chunk {
  const _Chunk({required this.dataLen, required this.type, required this.dataStart, required this.crcOk});
  final int dataLen;
  final String type;
  final int dataStart;
  final bool crcOk;

  int get total => 12 + dataLen;
}

bool _hasSignature(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return false;
  for (var i = 0; i < 8; i++) {
    if (bytes[offset + i] != _pngSignature[i]) return false;
  }
  return true;
}

int _findSignature(Uint8List bytes, [int from = 0]) {
  for (var p = from; p + 8 <= bytes.length; p++) {
    if (_hasSignature(bytes, p)) return p;
  }
  return -1;
}

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

Uint8List _gatherIdat(Uint8List src, List<_Chunk> chunks) {
  final b = BytesBuilder(copy: false);
  for (final c in chunks) {
    if (c.type == 'IDAT') b.add(Uint8List.sublistView(src, c.dataStart, c.dataStart + c.dataLen));
  }
  return b.toBytes();
}

Uint8List? _inflateZlib(Uint8List z) {
  if (z.isEmpty) return null;
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(z));
  } catch (_) {
    return null;
  }
}

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

({int compressed, int inflated}) _pngNestedContent(Uint8List src, List<_Chunk> chunks) {
  var compressed = 0, inflated = 0;
  var idatCompressed = 0;
  for (final c in chunks) {
    if (c.type == 'IDAT') idatCompressed += c.dataLen;
  }
  final raster = _inflateZlib(_gatherIdat(src, chunks));
  if (raster != null) {
    compressed += idatCompressed;
    inflated += raster.length;
  }
  for (final c in chunks) {
    if (!_ancillaryCompressedTypes.contains(c.type)) continue;
    final data = Uint8List.sublistView(src, c.dataStart, c.dataStart + c.dataLen);
    final zStart = _ancillaryZlibStart(c.type, data);
    if (zStart < 0) continue;
    final infl = _inflateZlib(Uint8List.sublistView(data, zStart));
    if (infl == null) continue;
    compressed += data.length - zStart;
    inflated += infl.length;
  }
  return (compressed: compressed, inflated: inflated);
}

void _emitPng(Uint8List src, int start, List<_Chunk> chunks, BytesBuilder out, _Split acc) {
  out.add(_pngSignature);
  acc.model += 8;
  for (final chunk in chunks) {
    // BytesBuilder(copy: false) retains adds by reference, so each chunk needs fresh buffers.
    final len = Uint8List(4);
    ByteData.sublistView(len).setUint32(0, chunk.dataLen);
    out.add(len);
    out.add(Uint8List.sublistView(src, chunk.dataStart - 4, chunk.dataStart));
    out.add(Uint8List.sublistView(src, chunk.dataStart, chunk.dataStart + chunk.dataLen));
    final crc = Uint8List(4);
    ByteData.sublistView(crc).setUint32(0, crc32(src, chunk.dataStart - 4, chunk.dataStart + chunk.dataLen));
    out.add(crc);
    acc.model += 8;
    if (chunk.crcOk) {
      acc.model += 4;
    } else {
      acc.copied += 4;
    }
    if (chunk.type == 'IDAT') {
      acc.copied += chunk.dataLen;
    } else if (_ancillaryCompressedTypes.contains(chunk.type)) {
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

class _Split {
  int model = 0;
  int copied = 0;
}

bool _dsimHeaderValid(Uint8List p) {
  if (p.length < 40) return false;
  final v = ByteData.sublistView(p);
  if (v.getUint32(0) != 0) return false;
  if (v.getUint16(4) != v.getUint16(30)) return false;
  if (v.getUint16(6) != v.getUint16(32)) return false;
  if (v.getUint16(8) != v.getUint16(34)) return false;
  return v.getUint32(26) == 0 && v.getUint32(36) == 0;
}

ViImageBlock? decodeImageBlock(String tag, Uint8List payload) {
  return switch (tag) {
    'MNGI' => _decodeMngi(payload),
    'DSIM' => _decodeDsim(payload),
    _ => null,
  };
}

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

ViImageBlock? _decodeDsim(Uint8List payload) {
  if (!_dsimHeaderValid(payload)) return null;
  final signatureAt = _findSignature(payload);
  return signatureAt >= 0 ? _decodeDsimPng(payload, signatureAt) : _decodeDsimRaster(payload);
}

ViImageBlock? _decodeDsimPng(Uint8List payload, int signatureAt) {
  final walk = _walkPng(payload, signatureAt);
  if (walk == null) return null;
  final acc = _Split();
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(payload, 0, signatureAt));
  acc.model += signatureAt;
  _emitPng(payload, signatureAt, walk.chunks, out, acc);
  final trailer = payload.length - walk.end;
  if (trailer > 0) {
    out.add(Uint8List.sublistView(payload, walk.end));
    acc.copied += trailer;
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
    bytes: Uint8List.fromList(payload),
    modelBytes: bodyEnd,
    copiedBytes: trailer,
    pngChunks: 0,
    crcVerified: 0,
    isRaster: true,
  );
}
