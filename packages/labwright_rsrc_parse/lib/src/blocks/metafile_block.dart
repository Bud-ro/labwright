/// Byte-faithful framing for the `.vi` **metafile image blocks** — `PICT` (an
/// Apple QuickDraw version-2 picture) and `WEMF` (a Windows Enhanced Metafile).
///
/// Both are self-contained, documented graphics container formats embedded in a
/// VI resource block. This module walks each one's element stream (QuickDraw
/// opcodes / EMF records) element-by-element, tiling the whole block to the last
/// byte, and re-emits it byte-for-byte. The structural framing (opcode/record
/// headers, length prefixes, the picture/metafile header) is reconstructed from
/// typed fields (**model**); the variable payload interiors an element carries —
/// a compressed QuickTime image, an EMF record's parameter block — are retained
/// verbatim as opaque leaves (**copied**). A block is framed only when its
/// element walk terminates exactly at the end-of-picture / end-of-metafile
/// element sitting at the block's last byte; anything that does not tile cleanly
/// (a version this walk does not model, an element whose length is not
/// deterministically derivable) yields null and the caller keeps the block
/// verbatim.
///
/// **PICT** (QuickDraw picture, version 2, big-endian). Layout: `[u16 size]
/// [Rect picFrame (4 x u16)][u16 VersionOp 0x0011][u16 version 0x02FF]` then the
/// opcode stream. Each opcode is a big-endian `u16`; its data byte count is
/// fixed per the opcode (Inside Macintosh: Imaging With QuickDraw, Appendix A) or
/// self-describing via a leading length/size/count field; odd-size data is
/// followed by a word-alignment pad byte. The stream ends at `OpEndPic` (0x00FF).
/// The bulk of a picture's bytes is the opaque leaf of the `CompressedQuickTime`
/// opcode (0x8200) — a QuickTime-compressed image, retained byte-faithfully.
///
/// **WEMF** (Windows Enhanced Metafile / EMF, little-endian). A pure sequence of
/// records `[u32 iType][u32 nSize][params]` where `nSize` is the whole record's
/// byte count (a multiple of 4, including the 8-byte header); the stream is fully
/// self-describing and ends at `EMR_EOF` (iType 14). Each record's parameter
/// block is retained verbatim as an opaque leaf.
///
/// [frameMetafile] returns the re-emitted bytes (byte-identical to the input for
/// every framed instance) plus the model/copied byte split (`modelBytes +
/// copiedBytes == bytes.length`).
library;

import 'dart:typed_data';

/// Which metafile container a [ViMetafileFrame] describes.
enum ViMetafileKind {
  /// Apple QuickDraw picture, version 2 (big-endian).
  pictV2,

  /// Windows Enhanced Metafile (EMF, little-endian).
  emf,
}

/// A framed metafile block: the re-emitted [bytes] (equal to the framed payload)
/// plus the model/copied byte split and element count. [modelBytes] +
/// [copiedBytes] == `bytes.length`.
class ViMetafileFrame {
  const ViMetafileFrame({
    required this.kind,
    required this.bytes,
    required this.modelBytes,
    required this.copiedBytes,
    required this.elementCount,
  });

  /// The container format this frame describes.
  final ViMetafileKind kind;

  /// The re-emitted payload: reconstructed framing + retained opaque leaves,
  /// byte-identical to the input for every framed instance.
  final Uint8List bytes;

  /// Bytes emitted from a reconstructed typed field — the element/record headers,
  /// length prefixes, fixed operands, and the picture/metafile header.
  final int modelBytes;

  /// Bytes retained verbatim as opaque leaves — the variable payload interiors
  /// (a `CompressedQuickTime` image, an EMF record's parameter block, a region's
  /// interior, a text/comment run) plus any word-alignment pad.
  final int copiedBytes;

  /// The number of opcodes walked (`PICT`) or records walked (`WEMF`).
  final int elementCount;
}

/// Frames a metafile [payload] for [tag] (`PICT` or `WEMF`), or null when the
/// payload is not a recognized, cleanly-tiling metafile of that kind. See the
/// library doc for the model.
ViMetafileFrame? frameMetafile(String tag, Uint8List payload) => switch (tag) {
  'PICT' => framePictV2(payload),
  'WEMF' => frameEmf(payload),
  _ => null,
};

// ---------------------------------------------------------------------------
// PICT (QuickDraw picture, version 2)
// ---------------------------------------------------------------------------

/// The QuickDraw `VersionOp` opcode (0x0011) and the version-2 marker word
/// (0x02FF) that together head a version-2 picture, right after the picture
/// frame rectangle.
const int _pictVersionOp = 0x0011;
const int _pictVersion2 = 0x02FF;

/// The `OpEndPic` opcode (0x00FF) that terminates a version-2 picture's opcode
/// stream.
const int _pictOpEndPic = 0x00FF;

/// The extended-header opcode (0x0C00): a fixed 24-byte header (version, hRes,
/// vRes, source rect, reserved) in a version-2 picture.
const int _pictHeaderOp = 0x0C00;

/// The number of data bytes an [op] carries in a version-2 picture, or null when
/// the length is not deterministically derivable from the documented opcode
/// table (Inside Macintosh: Imaging With QuickDraw, Appendix A) — the walk then
/// bails and the block stays copied. [v] reads the big-endian data fields;
/// [dataStart] is the offset of the opcode's data (just past the 2-byte opcode).
///
/// Count is the data byte count **excluding** the word-alignment pad that
/// follows odd-size data; the walk adds the pad separately.
int? _pictOpcodeDataLength(int op, ByteData v, int dataStart) {
  // Fixed-size opcodes (data byte count fixed by the opcode).
  const fixed = <int, int>{
    0x0000: 0, // NOP
    0x0002: 8, // BkPat
    0x0003: 2, // TxFont
    0x0004: 1, // TxFace
    0x0005: 2, // TxMode
    0x0006: 4, // SpExtra
    0x0007: 4, // PnSize
    0x0008: 2, // PnMode
    0x0009: 8, // PnPat
    0x000A: 8, // FillPat
    0x000B: 4, // OvSize
    0x000C: 4, // Origin
    0x000D: 2, // TxSize
    0x000E: 4, // FgColor
    0x000F: 4, // BkColor
    0x0010: 8, // TxRatio
    0x0011: 2, // VersionOp (as a body opcode; the header form is consumed early)
    0x0015: 2, // PnLocHFrac
    0x0016: 2, // ChExtra
    0x001A: 6, // RGBFgCol
    0x001B: 6, // RGBBkCol
    0x001C: 0, // HiliteMode
    0x001D: 6, // HiliteColor
    0x001E: 0, // DefHilite
    0x001F: 6, // OpColor
    0x0020: 8, // Line
    0x0021: 4, // LineFrom
    0x0022: 6, // ShortLine
    0x0023: 2, // ShortLineFrom
    0x002D: 10, // lineJustify
    0x002E: 8, // glyphState
    0x00A0: 2, // ShortComment
    0x00FF: 0, // OpEndPic
    0x0C00: 24, // HeaderOp
  };
  final f = fixed[op];
  if (f != null) return f;

  // Rectangle / rounded-rect / oval / arc verbs and their reserved neighbours.
  if (op >= 0x0030 && op <= 0x0037) return 8; // frame/paint/…Rect + reserved
  if (op >= 0x0038 && op <= 0x003F) return 0; // …SameRect + reserved
  if (op >= 0x0040 && op <= 0x0047) return 8; // …RRect + reserved
  if (op >= 0x0048 && op <= 0x004F) return 0; // …SameRRect + reserved
  if (op >= 0x0050 && op <= 0x0057) return 8; // …Oval + reserved
  if (op >= 0x0058 && op <= 0x005F) return 0; // …SameOval + reserved
  if (op >= 0x0060 && op <= 0x0067) return 12; // …Arc + reserved
  if (op >= 0x0068 && op <= 0x006F) return 4; // …SameArc + reserved
  if (op >= 0x0078 && op <= 0x007F) return 0; // …SamePoly + reserved
  if (op >= 0x0088 && op <= 0x008F) return 0; // …SameRgn + reserved

  // Region / polygon verbs: `[u16 size][…]`, size = total data byte count
  // (including the size word itself).
  if (op == 0x0001 || (op >= 0x0070 && op <= 0x0087)) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    final size = v.getUint16(dataStart);
    return size < 2 ? null : size;
  }

  // Text verbs with an embedded count byte.
  if (op == 0x0028) {
    // LongText: `[Point txLoc (4)][u8 count][text]`.
    if (dataStart + 5 > v.lengthInBytes) return null;
    return 5 + v.getUint8(dataStart + 4);
  }
  if (op == 0x0029 || op == 0x002A) {
    // DHText / DVText: `[u8 delta][u8 count][text]`.
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint8(dataStart + 1);
  }
  if (op == 0x002B) {
    // DHDVText: `[u8 dh][u8 dv][u8 count][text]`.
    if (dataStart + 3 > v.lengthInBytes) return null;
    return 3 + v.getUint8(dataStart + 2);
  }
  if (op == 0x002C) {
    // fontName: `[u16 dataLen][…]`, dataLen counts the bytes after it.
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint16(dataStart);
  }

  // LongComment: `[u16 kind][u16 size][data]`.
  if (op == 0x00A1) {
    if (dataStart + 4 > v.lengthInBytes) return null;
    return 4 + v.getUint16(dataStart + 2);
  }

  // Reserved ranges carrying `[u16 dataLen][data]`.
  if ((op >= 0x0024 && op <= 0x0027) ||
      op == 0x002F ||
      (op >= 0x0092 && op <= 0x0097) ||
      (op >= 0x009C && op <= 0x009F) ||
      (op >= 0x00A2 && op <= 0x00AF)) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint16(dataStart);
  }

  // Reserved / QuickTime ranges carrying `[u32 dataLen][data]`.
  if ((op >= 0x00D0 && op <= 0x00FE) ||
      (op >= 0x8100 && op <= 0x81FF) ||
      op == 0x8200 || // CompressedQuickTime
      op == 0x8201 || // UncompressedQuickTime
      op == 0xFFFF) {
    if (dataStart + 4 > v.lengthInBytes) return null;
    return 4 + v.getUint32(dataStart);
  }

  // Fixed-size reserved ranges.
  if (op >= 0x00B0 && op <= 0x00CF) return 0;
  if (op >= 0x0100 && op <= 0x01FF) return 2;
  if (op >= 0x0200 && op <= 0x0BFF) return 4;
  if (op >= 0x0C01 && op <= 0x7EFF) return 24;
  if (op >= 0x7F00 && op <= 0x7FFF) return 254;
  if (op >= 0x8000 && op <= 0x80FF) return 0;

  // Opcodes whose length is not deterministically derivable from the header
  // fields alone (raw/packed bitmap and pixel-pattern opcodes, whose PixData
  // length depends on the pixel-map geometry and pack type; reserved opcodes
  // whose data length is undocumented). None occur in the corpus; encountering
  // one bails the walk so the block stays copied rather than mis-sized.
  return null;
}

/// The model-byte fraction of an [op]'s framing: the length-determining fields
/// (size/length/count words) and understood fixed operands are model; a variable
/// trailing payload is copied. Given the opcode's total [dataLen] (excluding
/// pad), returns how many of those data bytes are model (the rest are copied).
int _pictOpcodeModelData(int op, int dataLen) {
  // Region / polygon: `[u16 size][Rect bounds (8)][rgnData]` — the size word and
  // bounds rect are model, the region interior is the opaque leaf.
  if (op == 0x0001 || (op >= 0x0070 && op <= 0x0087)) {
    return dataLen >= 10 ? 10 : dataLen;
  }
  // Text: the position/count framing is model, the text run is the opaque leaf.
  if (op == 0x0028) return dataLen >= 5 ? 5 : dataLen; // Point + count
  if (op == 0x0029 || op == 0x002A) return dataLen >= 2 ? 2 : dataLen;
  if (op == 0x002B) return dataLen >= 3 ? 3 : dataLen;
  if (op == 0x002C) return dataLen >= 2 ? 2 : dataLen; // dataLen word
  // LongComment: `[u16 kind][u16 size]` is model, the comment data is copied.
  if (op == 0x00A1) return dataLen >= 4 ? 4 : dataLen;
  // Reserved `[u16 dataLen][data]`: the length word is model, the data copied.
  if ((op >= 0x0024 && op <= 0x0027) ||
      op == 0x002F ||
      (op >= 0x0092 && op <= 0x0097) ||
      (op >= 0x009C && op <= 0x009F) ||
      (op >= 0x00A2 && op <= 0x00AF)) {
    return dataLen >= 2 ? 2 : dataLen;
  }
  // Reserved / QuickTime `[u32 dataLen][data]`: the length long is model, the
  // compressed image / private data is the opaque leaf.
  if ((op >= 0x00D0 && op <= 0x00FE) ||
      (op >= 0x8100 && op <= 0x81FF) ||
      op == 0x8200 ||
      op == 0x8201 ||
      op == 0xFFFF) {
    return dataLen >= 4 ? 4 : dataLen;
  }
  // Every other opcode carries a fixed, fully-understood operand block — all
  // model.
  return dataLen;
}

/// Frames a `PICT` [payload] as a QuickDraw version-2 picture, or null when it
/// is not a cleanly-tiling version-2 picture (a version this walk does not
/// model, an opcode whose length is not derivable, or a stream that does not end
/// at `OpEndPic` on the last byte).
ViMetafileFrame? framePictV2(Uint8List payload) {
  // Header: [u16 size][Rect (8)][u16 VersionOp][u16 version].
  if (payload.length < 14) return null;
  final v = ByteData.sublistView(payload);
  if (v.getUint16(10) != _pictVersionOp || v.getUint16(12) != _pictVersion2) return null;

  final out = BytesBuilder(copy: false);
  // The 10-byte header (size + picture frame) and the 4-byte version words are
  // reconstructed structural framing.
  out.add(Uint8List.sublistView(payload, 0, 14));
  var model = 14;
  var copied = 0;
  var pos = 14;
  var opcodes = 0;

  while (pos + 2 <= payload.length) {
    final op = v.getUint16(pos);
    final dataStart = pos + 2;
    final dataLen = _pictOpcodeDataLength(op, v, dataStart);
    if (dataLen == null) return null; // un-sizeable opcode — leave copied
    final dataEnd = dataStart + dataLen;
    if (dataEnd > payload.length) return null; // truncated element

    // Reconstruct the opcode word; retain the data span verbatim.
    final opw = Uint8List(2);
    ByteData.sublistView(opw).setUint16(0, op);
    out.add(opw);
    out.add(Uint8List.sublistView(payload, dataStart, dataEnd));
    model += 2;
    final modelData = _pictOpcodeModelData(op, dataLen);
    model += modelData;
    copied += dataLen - modelData;
    pos = dataEnd;
    opcodes++;

    // Word-alignment pad after odd-size data (a byte of 0 keeps the next opcode
    // word-aligned). Retained verbatim.
    if ((pos & 1) != 0) {
      if (pos >= payload.length) return null;
      out.add(Uint8List.sublistView(payload, pos, pos + 1));
      copied += 1;
      pos++;
    }

    if (op == _pictOpEndPic) {
      // A version-2 picture ends at OpEndPic on its last byte.
      if (pos != payload.length) return null;
      final bytes = out.toBytes();
      return ViMetafileFrame(
        kind: ViMetafileKind.pictV2,
        bytes: bytes,
        modelBytes: model,
        copiedBytes: copied,
        elementCount: opcodes,
      );
    }
    if (op == _pictHeaderOp) continue; // header already length-accounted
  }
  return null; // ran out before OpEndPic
}

// ---------------------------------------------------------------------------
// WEMF (Windows Enhanced Metafile / EMF)
// ---------------------------------------------------------------------------

/// The EMF record type of `EMR_HEADER` (the first record of every metafile).
const int _emrHeader = 0x00000001;

/// The EMF record type of `EMR_EOF` (the last record of every metafile).
const int _emrEof = 0x0000000E;

/// The ` EMF` signature (`0x464D4520` little-endian) at offset 40 of an
/// `EMR_HEADER` record, distinguishing an EMF from a placeable/classic WMF.
const int _emfSignature = 0x464D4520;

/// The 8-byte EMF record header (`[u32 iType][u32 nSize]`), reconstructed as
/// model for every record.
const int _emfRecordHeaderLen = 8;

/// Frames a `WEMF` [payload] as a Windows Enhanced Metafile, or null when it is
/// not a cleanly-tiling EMF (a non-EMF magic, a record whose size is out of
/// range or not 4-aligned, or a stream that does not end at `EMR_EOF` on the last
/// byte).
ViMetafileFrame? frameEmf(Uint8List payload) {
  // The metafile opens with EMR_HEADER (iType 1) carrying the " EMF" signature.
  if (payload.length < 48) return null;
  final v = ByteData.sublistView(payload);
  if (v.getUint32(0, Endian.little) != _emrHeader) return null;
  if (v.getUint32(40, Endian.little) != _emfSignature) return null;

  final out = BytesBuilder(copy: false);
  var model = 0;
  var copied = 0;
  var pos = 0;
  var records = 0;

  while (pos + _emfRecordHeaderLen <= payload.length) {
    final iType = v.getUint32(pos, Endian.little);
    final nSize = v.getUint32(pos + 4, Endian.little);
    // nSize is the whole record's byte count including the 8-byte header, a
    // multiple of 4; a value that violates that or overruns the block is not a
    // valid record boundary.
    if (nSize < _emfRecordHeaderLen || (nSize & 3) != 0 || pos + nSize > payload.length) return null;

    // Reconstruct the record header (iType + nSize); retain the parameter block
    // verbatim as an opaque leaf.
    final hdr = Uint8List(_emfRecordHeaderLen);
    final hv = ByteData.sublistView(hdr);
    hv.setUint32(0, iType, Endian.little);
    hv.setUint32(4, nSize, Endian.little);
    out.add(hdr);
    out.add(Uint8List.sublistView(payload, pos + _emfRecordHeaderLen, pos + nSize));
    model += _emfRecordHeaderLen;
    copied += nSize - _emfRecordHeaderLen;
    pos += nSize;
    records++;

    if (iType == _emrEof) {
      if (pos != payload.length) return null; // EMR_EOF must be the last record
      final bytes = out.toBytes();
      return ViMetafileFrame(
        kind: ViMetafileKind.emf,
        bytes: bytes,
        modelBytes: model,
        copiedBytes: copied,
        elementCount: records,
      );
    }
  }
  return null; // ran out before EMR_EOF
}
