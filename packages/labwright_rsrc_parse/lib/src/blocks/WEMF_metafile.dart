/// `WEMF` - Windows Enhanced Metafile: [ViEmfMetafile]
///
/// An EMR_HEADER record followed by self-sized little-endian records ending at EMR_EOF.
///
/// ```text
/// offset  size  field        type        meaning
/// 0       4     iType        u32le       EMR_HEADER = 1.
/// 4       4     nSize        u32le       Bytes of the header record.
/// 8       4     boundsLeft   i32le       Left of the inclusive bounds rectangle.
/// 12      4     boundsTop    i32le       Top of the bounds rectangle.
/// 16      4     boundsRight  i32le       Right of the bounds rectangle.
/// 20      4     boundsBottom i32le       Bottom of the bounds rectangle.
/// 24      16    unknown24                Four i32le words: two zero, two that vary; roles TODO.
/// 40      4     signature    4cc         " EMF".
/// 44      rest  headerRest               not decoded
/// …       rest  records      EmfRecord[] Records from the header to EMR_EOF.
///   +0    4     iType        u32le       Record type; EMR_EOF = 14 last.
///   +4    4     nSize        u32le       Bytes of the record, a multiple of 4.
///   +8    rest  params       u8[]        Record parameters, nSize - 8 bytes.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

const int _emrHeader = 0x00000001;
const int _emrEof = 0x0000000E;
const _emfSignature = ' EMF';
const int _minHeaderBytes = 48;

/// Byte accounting of a metafile's opcode or record stream.
class ViMetafileFrame {
  const ViMetafileFrame({required this.modelBytes, required this.copiedBytes, required this.elementCount});

  /// Bytes the model derives: framing plus the parameters it names.
  final int modelBytes;

  /// Parameter bytes retained opaque.
  final int copiedBytes;

  /// Opcodes or records in the stream.
  final int elementCount;
}

final class ViEmfMetafile extends ByteRecord {
  ViEmfMetafile(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes >= _minHeaderBytes, 'EMF starts with a 48-byte or longer header record');
    assert(_iType.read(view) == _emrHeader, 'the first record is EMR_HEADER');
    assert(_signature.read(view) == _emfSignature, 'the header carries the EMF signature');
    final frame = _frameEmf(view);
    assert(frame != null, 'the records tile to EMR_EOF at the end of the payload');
    this.frame = frame!;
  }

  /// Byte accounting of the record stream.
  late final ViMetafileFrame frame;

  /// Left of the inclusive bounds rectangle.
  int get boundsLeft => _boundsLeft.read(view);

  /// Top of the bounds rectangle.
  int get boundsTop => _boundsTop.read(view);

  /// Right of the bounds rectangle.
  int get boundsRight => _boundsRight.read(view);

  /// Bottom of the bounds rectangle.
  int get boundsBottom => _boundsBottom.read(view);

  // dart format off
  static const _iType = U32(0, endian: Endian.little); // EMR_HEADER = 1.
  static const _nSize = U32(4, endian: Endian.little); // Bytes of the header record.
  static const _boundsLeft = I32(8, endian: Endian.little);
  static const _boundsTop = I32(12, endian: Endian.little);
  static const _boundsRight = I32(16, endian: Endian.little);
  static const _boundsBottom = I32(20, endian: Endian.little);
  static const _unknown24 = Unknown(24, size: 16); // Four i32le words: two zero, two that vary; roles TODO.
  static const _signature = FourCc(40); // " EMF".
  static const _headerRest = Unknown(44);
  static const _records = Entries(0, EmfRecord.layout); // Records from the header to EMR_EOF.

  static const layout = ByteLayout([_iType, _nSize, _boundsLeft, _boundsTop, _boundsRight, _boundsBottom, _unknown24, _signature, _headerRest, _records]);
  // dart format on
}

/// One metafile record.
abstract final class EmfRecord {
  static const iType = U32(0, endian: Endian.little); // Record type; EMR_EOF = 14 last.
  static const nSize = U32(4, endian: Endian.little); // Bytes of the record, a multiple of 4.
  static const params = Bytes(8); // Record parameters, nSize - 8 bytes.

  static const layout = ByteLayout([iType, nSize, params]);
}

int _emfModelParamBytes(int iType, int paramLen) {
  const fixed = <int, int>{
    0x09: 8,
    0x0A: 8,
    0x0B: 8,
    0x0C: 8,
    0x0D: 8,
    0x11: 4,
    0x12: 4,
    0x13: 4,
    0x14: 4,
    0x15: 4,
    0x16: 4,
    0x18: 4,
    0x19: 4,
    0x25: 4,
    0x26: 20,
    0x28: 4,
    0x30: 4,
    0x34: 0,
  };
  final f = fixed[iType];
  if (f != null) return f <= paramLen ? f : paramLen;
  final prefix = switch (iType) {
    0x01 => 80,
    0x0E => 8,
    0x31 => 8,
    0x46 => 4,
    0x4B => 8,
    0x4C => 92,
    0x51 => 72,
    0x52 => 4,
    0x72 => 100,
    _ => 0,
  };
  return prefix <= paramLen ? prefix : paramLen;
}

ViMetafileFrame? _frameEmf(ByteData v) {
  final headerBytes = EmfRecord.params.offset;
  var model = 0;
  var copied = 0;
  var pos = 0;
  var records = 0;
  while (pos + headerBytes <= v.lengthInBytes) {
    final iType = v.getUint32(pos + EmfRecord.iType.offset, Endian.little);
    final nSize = v.getUint32(pos + EmfRecord.nSize.offset, Endian.little);
    if (nSize < headerBytes || (nSize & 3) != 0 || pos + nSize > v.lengthInBytes) return null;
    final paramLen = nSize - headerBytes;
    final modelParam = _emfModelParamBytes(iType, paramLen);
    model += headerBytes + modelParam;
    copied += paramLen - modelParam;
    pos += nSize;
    records++;
    if (iType == _emrEof) {
      if (pos != v.lengthInBytes) return null;
      return ViMetafileFrame(modelBytes: model, copiedBytes: copied, elementCount: records);
    }
  }
  return null;
}
