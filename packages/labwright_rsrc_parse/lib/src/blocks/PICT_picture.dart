/// `PICT` - QuickDraw Picture: [ViPictPicture]
///
/// A QuickDraw PICT version 2 picture: the picture frame, the version opcode, then a
/// big-endian opcode stream padded to even offsets and ending at OpEndPic. A
/// CompressedQuickTime opcode carrying an uncompressed `raw ` image is read through
/// [ViQuickTimeRaster].
///
/// ```text
/// offset  size  field     type         meaning
/// 0       2     size      u16          Picture size, low 16 bits.
/// 2       2     top       i16          Picture frame top.
/// 4       2     left      i16          Picture frame left.
/// 6       2     bottom    i16          Picture frame bottom.
/// 8       2     right     i16          Picture frame right.
/// 10      2     versionOp u16          0x0011.
/// 12      2     version   u16          0x02FF.
/// 14      rest  opcodes   PictOpcode[] Opcodes to OpEndPic (0x00FF).
///   +0    2     opcode    u16          QuickDraw opcode.
///   +2    rest  data      u8[]         Opcode data, sized by opcode; padded to an even offset.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'WEMF_metafile.dart' show ViMetafileFrame;

/// One QuickDraw opcode.
abstract final class PictOpcode {
  static const opcode = U16(0); // QuickDraw opcode.
  static const data = Bytes(2); // Opcode data, sized by opcode; padded to an even offset.

  static const layout = ByteLayout([opcode, data]);
}

const int _pictVersionOp = 0x0011;
const int _pictVersion2 = 0x02FF;
const int _pictOpEndPic = 0x00FF;
const int _compressedQuickTime = 0x8200;
const int _qtRawCodec = 0x72617720;

final class ViPictPicture extends ByteRecord {
  ViPictPicture(Uint8List bytes) : super(bytes, layout) {
    assert(_versionOp.read(view) == _pictVersionOp && _version.read(view) == _pictVersion2, 'PICT is version 2');
    final framed = _framePict(view);
    assert(framed != null, 'the opcodes tile to OpEndPic at the end of the payload');
    frame = framed!;
  }

  /// Byte accounting of the opcode stream.
  late final ViMetafileFrame frame;

  /// Picture frame top.
  int get top => _top.read(view);

  /// Picture frame left.
  int get left => _left.read(view);

  /// Picture frame bottom.
  int get bottom => _bottom.read(view);

  /// Picture frame right.
  int get right => _right.read(view);

  int get width => right - left;

  int get height => bottom - top;

  /// The first CompressedQuickTime opcode holding an uncompressed `raw ` image, or null.
  ViQuickTimeRaster? get quickTimeRaster {
    var pos = _opcodes.offset;
    while (pos + PictOpcode.data.offset <= view.lengthInBytes) {
      final op = view.getUint16(pos);
      final dataStart = pos + PictOpcode.data.offset;
      final dataLen = _pictOpcodeDataLength(op, view, dataStart)!;
      if (op == _compressedQuickTime && _quickTimeRawExtent(view, dataStart, dataLen) != null) {
        return ViQuickTimeRaster(view, dataStart + 4 + 68);
      }
      pos = dataStart + dataLen;
      if ((pos & 1) != 0) pos++;
      if (op == _pictOpEndPic) return null;
    }
    return null;
  }

  static const _size = U16(0); // Picture size, low 16 bits.
  static const _top = I16(2);
  static const _left = I16(4);
  static const _bottom = I16(6);
  static const _right = I16(8);
  static const _versionOp = U16(10); // 0x0011.
  static const _version = U16(12); // 0x02FF.
  static const _opcodes = Entries(14, PictOpcode.layout); // Opcodes to OpEndPic (0x00FF).

  static const layout = ByteLayout([_size, _top, _left, _bottom, _right, _versionOp, _version, _opcodes]);
}

/// The uncompressed `raw ` image of a CompressedQuickTime opcode: a QuickTime ImageDescription
/// followed by `rowBytes × height` packed pixels.
final class ViQuickTimeRaster {
  const ViQuickTimeRaster(this.view, this._descriptionOffset);

  final ByteData view;

  final int _descriptionOffset;

  int get width => view.getUint16(_descriptionOffset + 32);

  int get height => view.getUint16(_descriptionOffset + 34);

  /// Bits per pixel: 24 or 32.
  int get depth => view.getUint16(_descriptionOffset + 82);

  Uint8List get pixels {
    final start = _descriptionOffset + view.getUint32(_descriptionOffset);
    return Uint8List.sublistView(view, start, start + (width * depth ~/ 8) * height);
  }
}

int? _pictOpcodeDataLength(int op, ByteData v, int dataStart) {
  const fixed = <int, int>{
    0x0000: 0,
    0x0002: 8,
    0x0003: 2,
    0x0004: 1,
    0x0005: 2,
    0x0006: 4,
    0x0007: 4,
    0x0008: 2,
    0x0009: 8,
    0x000A: 8,
    0x000B: 4,
    0x000C: 4,
    0x000D: 2,
    0x000E: 4,
    0x000F: 4,
    0x0010: 8,
    0x0011: 2,
    0x0015: 2,
    0x0016: 2,
    0x001A: 6,
    0x001B: 6,
    0x001C: 0,
    0x001D: 6,
    0x001E: 0,
    0x001F: 6,
    0x0020: 8,
    0x0021: 4,
    0x0022: 6,
    0x0023: 2,
    0x002D: 10,
    0x002E: 8,
    0x00A0: 2,
    0x00FF: 0,
    0x0C00: 24,
  };
  final f = fixed[op];
  if (f != null) return f;

  if (op >= 0x0030 && op <= 0x0037) return 8;
  if (op >= 0x0038 && op <= 0x003F) return 0;
  if (op >= 0x0040 && op <= 0x0047) return 8;
  if (op >= 0x0048 && op <= 0x004F) return 0;
  if (op >= 0x0050 && op <= 0x0057) return 8;
  if (op >= 0x0058 && op <= 0x005F) return 0;
  if (op >= 0x0060 && op <= 0x0067) return 12;
  if (op >= 0x0068 && op <= 0x006F) return 4;
  if (op >= 0x0078 && op <= 0x007F) return 0;
  if (op >= 0x0088 && op <= 0x008F) return 0;

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
      op == _compressedQuickTime ||
      op == 0x8201 ||
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

/// The bytes of a CompressedQuickTime opcode this package understands (QuickTime fields, an
/// ImageDescription and its `raw ` pixels), or null when the codec or matte/mask differ.
int? _quickTimeRawExtent(ByteData v, int dataStart, int dataLen) {
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
  if (op == 0x0001 || (op >= 0x0070 && op <= 0x0087)) return dataLen >= 10 ? 10 : dataLen;
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
  if (op == _compressedQuickTime) {
    final understood = _quickTimeRawExtent(v, dataStart, dataLen);
    if (understood != null) return understood;
    return dataLen >= 4 ? 4 : dataLen;
  }
  if ((op >= 0x00D0 && op <= 0x00FE) || (op >= 0x8100 && op <= 0x81FF) || op == 0x8201 || op == 0xFFFF) {
    return dataLen >= 4 ? 4 : dataLen;
  }
  return dataLen;
}

ViMetafileFrame? _framePict(ByteData v) {
  var model = ViPictPicture._opcodes.offset;
  var copied = 0;
  var pos = ViPictPicture._opcodes.offset;
  var opcodes = 0;
  while (pos + 2 <= v.lengthInBytes) {
    final op = v.getUint16(pos);
    final dataStart = pos + 2;
    final dataLen = _pictOpcodeDataLength(op, v, dataStart);
    if (dataLen == null) return null;
    final dataEnd = dataStart + dataLen;
    if (dataEnd > v.lengthInBytes) return null;
    final modelData = _pictOpcodeModelData(op, v, dataStart, dataLen);
    model += 2 + modelData;
    copied += dataLen - modelData;
    pos = dataEnd;
    opcodes++;
    if ((pos & 1) != 0) {
      if (pos >= v.lengthInBytes) return null;
      copied += 1;
      pos++;
    }
    if (op == _pictOpEndPic) {
      if (pos != v.lengthInBytes) return null;
      return ViMetafileFrame(modelBytes: model, copiedBytes: copied, elementCount: opcodes);
    }
  }
  return null;
}
