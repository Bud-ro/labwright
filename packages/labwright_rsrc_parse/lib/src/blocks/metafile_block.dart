import 'dart:typed_data';

enum ViMetafileKind {
  pictV2,

  emf,
}

class ViMetafileFrame {
  const ViMetafileFrame({
    required this.kind,
    required this.bytes,
    required this.modelBytes,
    required this.copiedBytes,
    required this.elementCount,
  });

  final ViMetafileKind kind;

  final Uint8List bytes;

  final int modelBytes;

  final int copiedBytes;

  final int elementCount;
}

ViMetafileFrame? frameMetafile(String tag, Uint8List payload) => switch (tag) {
  'PICT' => framePictV2(payload),
  'WEMF' => frameEmf(payload),
  _ => null,
};

const int _pictVersionOp = 0x0011;
const int _pictVersion2 = 0x02FF;

const int _pictOpEndPic = 0x00FF;

const int _pictHeaderOp = 0x0C00;

int? _pictOpcodeDataLength(int op, ByteData v, int dataStart) {
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
    0x0011: 2, // VersionOp
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

  if (op == 0x0001 || (op >= 0x0070 && op <= 0x0087)) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    final size = v.getUint16(dataStart);
    return size < 2 ? null : size;
  }

  if (op == 0x0028) {
    if (dataStart + 5 > v.lengthInBytes) return null;
    return 5 + v.getUint8(dataStart + 4);
  }
  if (op == 0x0029 || op == 0x002A) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint8(dataStart + 1);
  }
  if (op == 0x002B) {
    if (dataStart + 3 > v.lengthInBytes) return null;
    return 3 + v.getUint8(dataStart + 2);
  }
  if (op == 0x002C) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint16(dataStart);
  }

  if (op == 0x00A1) {
    if (dataStart + 4 > v.lengthInBytes) return null;
    return 4 + v.getUint16(dataStart + 2);
  }

  if ((op >= 0x0024 && op <= 0x0027) ||
      op == 0x002F ||
      (op >= 0x0092 && op <= 0x0097) ||
      (op >= 0x009C && op <= 0x009F) ||
      (op >= 0x00A2 && op <= 0x00AF)) {
    if (dataStart + 2 > v.lengthInBytes) return null;
    return 2 + v.getUint16(dataStart);
  }

  if ((op >= 0x00D0 && op <= 0x00FE) ||
      (op >= 0x8100 && op <= 0x81FF) ||
      op == 0x8200 || // CompressedQuickTime
      op == 0x8201 || // UncompressedQuickTime
      op == 0xFFFF) {
    if (dataStart + 4 > v.lengthInBytes) return null;
    return 4 + v.getUint32(dataStart);
  }

  if (op >= 0x00B0 && op <= 0x00CF) return 0;
  if (op >= 0x0100 && op <= 0x01FF) return 2;
  if (op >= 0x0200 && op <= 0x0BFF) return 4;
  if (op >= 0x0C01 && op <= 0x7EFF) return 24;
  if (op >= 0x7F00 && op <= 0x7FFF) return 254;
  if (op >= 0x8000 && op <= 0x80FF) return 0;

  return null;
}

const int _qtRawCodec = 0x72617720; // 'raw '

class ViQuickTimeRaster {
  const ViQuickTimeRaster({
    required this.width,
    required this.height,
    required this.depth,
    required this.pixels,
  });

  final int width;
  final int height;

  final int depth;

  final Uint8List pixels;
}

ViQuickTimeRaster? decodePictQuickTimeRaster(Uint8List payload) {
  if (payload.length < 14) return null;
  final v = ByteData.sublistView(payload);
  if (v.getUint16(10) != _pictVersionOp || v.getUint16(12) != _pictVersion2) {
    return null;
  }
  var pos = 14;
  while (pos + 2 <= payload.length) {
    final op = v.getUint16(pos);
    final dataStart = pos + 2;
    final dataLen = _pictOpcodeDataLength(op, v, dataStart);
    if (dataLen == null || dataStart + dataLen > payload.length) return null;
    if (op == 0x8200 && _quickTimeRawExtent(v, dataStart, dataLen) != null) {
      final idStart = dataStart + 4 + 68;
      final idSize = v.getUint32(idStart);
      final width = v.getUint16(idStart + 32);
      final height = v.getUint16(idStart + 34);
      final depth = v.getUint16(idStart + 82);
      final rasterStart = idStart + idSize;
      final rasterLen = (width * depth ~/ 8) * height;
      return ViQuickTimeRaster(
        width: width,
        height: height,
        depth: depth,
        pixels: Uint8List.sublistView(payload, rasterStart, rasterStart + rasterLen),
      );
    }
    pos = dataStart + dataLen;
    if ((pos & 1) != 0) pos++;
    if (op == _pictOpEndPic) return null;
  }
  return null;
}

int? _quickTimeRawExtent(ByteData v, int dataStart, int dataLen) {
  // [u32 opcodeSize][version u16][matrix 36][matteSize u32][matteRect 8]
  // [mode u16][srcRect 8][accuracy u32][maskSize u32] then ImageDescription.
  final qt = dataStart + 4;
  final idStart = qt + 68;
  if (idStart + 84 > dataStart + dataLen) return null;
  final matteSize = v.getUint32(qt + 38);
  final maskSize = v.getUint32(qt + 64);
  if (matteSize != 0 || maskSize != 0) return null;
  final idSize = v.getUint32(idStart);
  final cType = v.getUint32(idStart + 4);
  if (cType != _qtRawCodec) return null;
  final width = v.getUint16(idStart + 32);
  final height = v.getUint16(idStart + 34);
  final dataSize = v.getUint32(idStart + 44);
  final depth = v.getUint16(idStart + 82);
  if (width == 0 || height == 0 || (width * depth) % 8 != 0) return null;
  final rowBytes = (width * depth) ~/ 8;
  if (dataSize != rowBytes * height) return null;
  final understood = (idStart - dataStart) + idSize + dataSize;
  if (understood > dataLen) return null;
  return understood;
}

int _pictOpcodeModelData(int op, ByteData v, int dataStart, int dataLen) {
  if (op == 0x0001 || (op >= 0x0070 && op <= 0x0087)) {
    return dataLen >= 10 ? 10 : dataLen;
  }
  if (op == 0x0028) return dataLen >= 5 ? 5 : dataLen;
  if (op == 0x0029 || op == 0x002A) return dataLen >= 2 ? 2 : dataLen;
  if (op == 0x002B) return dataLen >= 3 ? 3 : dataLen;
  if (op == 0x002C) return dataLen >= 2 ? 2 : dataLen;
  if (op == 0x00A1) return dataLen >= 4 ? 4 : dataLen;
  if ((op >= 0x0024 && op <= 0x0027) ||
      op == 0x002F ||
      (op >= 0x0092 && op <= 0x0097) ||
      (op >= 0x009C && op <= 0x009F) ||
      (op >= 0x00A2 && op <= 0x00AF)) {
    return dataLen >= 2 ? 2 : dataLen;
  }
  if (op == 0x8200) {
    final understood = _quickTimeRawExtent(v, dataStart, dataLen);
    if (understood != null) return understood;
    return dataLen >= 4 ? 4 : dataLen;
  }
  if ((op >= 0x00D0 && op <= 0x00FE) || (op >= 0x8100 && op <= 0x81FF) || op == 0x8201 || op == 0xFFFF) {
    return dataLen >= 4 ? 4 : dataLen;
  }
  return dataLen;
}

ViMetafileFrame? framePictV2(Uint8List payload) {
  if (payload.length < 14) return null;
  final v = ByteData.sublistView(payload);
  if (v.getUint16(10) != _pictVersionOp || v.getUint16(12) != _pictVersion2) return null;

  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(payload, 0, 14));
  var model = 14;
  var copied = 0;
  var pos = 14;
  var opcodes = 0;

  while (pos + 2 <= payload.length) {
    final op = v.getUint16(pos);
    final dataStart = pos + 2;
    final dataLen = _pictOpcodeDataLength(op, v, dataStart);
    if (dataLen == null) return null;
    final dataEnd = dataStart + dataLen;
    if (dataEnd > payload.length) return null;

    final opw = Uint8List(2);
    ByteData.sublistView(opw).setUint16(0, op);
    out.add(opw);
    out.add(Uint8List.sublistView(payload, dataStart, dataEnd));
    model += 2;
    final modelData = _pictOpcodeModelData(op, v, dataStart, dataLen);
    model += modelData;
    copied += dataLen - modelData;
    pos = dataEnd;
    opcodes++;

    if ((pos & 1) != 0) {
      if (pos >= payload.length) return null;
      out.add(Uint8List.sublistView(payload, pos, pos + 1));
      copied += 1;
      pos++;
    }

    if (op == _pictOpEndPic) {
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
    if (op == _pictHeaderOp) continue;
  }
  return null;
}

const int _emrHeader = 0x00000001;

const int _emrEof = 0x0000000E;

const int _emfSignature = 0x464D4520;

const int _emfRecordHeaderLen = 8;

int _emfModelParamBytes(int iType, int paramLen) {
  const fixed = <int, int>{
    0x09: 8, // EMR_SETWINDOWEXTEX
    0x0A: 8, // EMR_SETWINDOWORGEX
    0x0B: 8, // EMR_SETVIEWPORTEXTEX
    0x0C: 8, // EMR_SETVIEWPORTORGEX
    0x0D: 8, // EMR_SETBRUSHORGEX
    0x11: 4, // EMR_SETMAPMODE
    0x12: 4, // EMR_SETBKMODE
    0x13: 4, // EMR_SETPOLYFILLMODE
    0x14: 4, // EMR_SETROP2
    0x15: 4, // EMR_SETSTRETCHBLTMODE
    0x16: 4, // EMR_SETTEXTALIGN
    0x18: 4, // EMR_SETTEXTCOLOR
    0x19: 4, // EMR_SETBKCOLOR
    0x25: 4, // EMR_SELECTOBJECT
    0x26: 20, // EMR_CREATEPEN
    0x28: 4, // EMR_DELETEOBJECT
    0x30: 4, // EMR_SELECTPALETTE
    0x34: 0, // EMR_REALIZEPALETTE
  };
  final f = fixed[iType];
  if (f != null) return f <= paramLen ? f : paramLen;

  final prefix = switch (iType) {
    0x01 => 80, // EMR_HEADER
    0x0E => 8, // EMR_EOF
    0x31 => 8, // EMR_CREATEPALETTE
    0x46 => 4, // EMR_COMMENT
    0x4B => 8, // EMR_EXTSELECTCLIPRGN
    0x4C => 92, // EMR_BITBLT
    0x51 => 72, // EMR_STRETCHDIBITS
    0x52 => 4, // EMR_EXTCREATEFONTINDIRECTW
    0x72 => 100, // EMR_ALPHABLEND
    _ => 0,
  };
  return prefix <= paramLen ? prefix : paramLen;
}

ViMetafileFrame? frameEmf(Uint8List payload) {
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
    if (nSize < _emfRecordHeaderLen || (nSize & 3) != 0 || pos + nSize > payload.length) return null;

    final hdr = Uint8List(_emfRecordHeaderLen);
    final hv = ByteData.sublistView(hdr);
    hv.setUint32(0, iType, Endian.little);
    hv.setUint32(4, nSize, Endian.little);
    out.add(hdr);
    out.add(Uint8List.sublistView(payload, pos + _emfRecordHeaderLen, pos + nSize));
    final paramLen = nSize - _emfRecordHeaderLen;
    final modelParam = _emfModelParamBytes(iType, paramLen);
    model += _emfRecordHeaderLen + modelParam;
    copied += paramLen - modelParam;
    pos += nSize;
    records++;

    if (iType == _emrEof) {
      if (pos != payload.length) return null;
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
  return null;
}
