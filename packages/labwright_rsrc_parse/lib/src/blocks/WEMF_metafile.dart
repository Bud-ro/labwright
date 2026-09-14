/// `WEMF` — a Windows enhanced metafile: an EMR_HEADER record, then self-sized little-endian
/// records ending at EMR_EOF.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     iType                      u32le    EMR_HEADER = 1
/// 4       4     nSize                      u32le    bytes of the header record
/// 8       4     boundsLeft                 i32le    left of the inclusive bounds rectangle
/// 12      4     boundsTop                  i32le    top of the bounds rectangle
/// 16      4     boundsRight                i32le    right of the bounds rectangle
/// 20      4     boundsBottom               i32le    bottom of the bounds rectangle
/// 24      16    TODO                       i32le[4] retained; not decoded
/// 40      4     signature                  4cc      " EMF" (0x464D4520 little-endian)
/// 44      rest  TODO                                retained; not decoded
/// …       rest  records                    entry[]  records from the header to EMR_EOF
///   +0    4     iType                      u32le    record type; EMR_EOF = 14 last
///   +4    4     nSize                      u32le    bytes of the record, a multiple of 4
///   +8    rest  params                     u8[nSize - 8] record parameters
/// ```
///
/// [ViEmfMetafile] is a view over the payload whose [ViEmfMetafile.frame] accounts for the
/// record stream; [decodeEmf] requires the header record, its ` EMF` signature, and the
/// records to tile the payload to EMR_EOF. [ViMetafileFrame] is the accounting `PICT` shares.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _headerType = BlockField(0, 4, 'iType', 'u32le', 'EMR_HEADER = 1');
const _headerSize = BlockField(4, 4, 'nSize', 'u32le', 'bytes of the header record');
const _boundsLeft = BlockField(8, 4, 'boundsLeft', 'i32le', 'left of the inclusive bounds rectangle');
const _boundsTop = BlockField(12, 4, 'boundsTop', 'i32le', 'top of the bounds rectangle');
const _boundsRight = BlockField(16, 4, 'boundsRight', 'i32le', 'right of the bounds rectangle');
const _boundsBottom = BlockField(20, 4, 'boundsBottom', 'i32le', 'bottom of the bounds rectangle');
const _todo24 = BlockField.undecoded(24, 16, type: 'i32le[4]');
const _signature = BlockField(40, 4, 'signature', '4cc', '" EMF" (0x464D4520 little-endian)');
const _headerRest = BlockField.undecoded(44, null);
const _recordType = BlockField(0, 4, 'iType', 'u32le', 'record type; EMR_EOF = 14 last');
const _recordSize = BlockField(4, 4, 'nSize', 'u32le', 'bytes of the record, a multiple of 4');
const _recordParams = BlockField(8, null, 'params', 'u8[nSize - 8]', 'record parameters');
const _records = BlockField(
  0,
  null,
  'records',
  'entry[]',
  'records from the header to EMR_EOF',
  entry: [_recordType, _recordSize, _recordParams],
);

const BlockLayout wemfLayout = [
  _headerType,
  _headerSize,
  _boundsLeft,
  _boundsTop,
  _boundsRight,
  _boundsBottom,
  _todo24,
  _signature,
  _headerRest,
  _records,
];

const int _emrHeader = 0x00000001;
const int _emrEof = 0x0000000E;
const int _emfSignature = 0x464D4520;
const int _recordHeaderBytes = 8;
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

/// A view over a `WEMF` payload.
class ViEmfMetafile {
  ViEmfMetafile._(this.bytes, this.frame) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  /// Byte accounting of the record stream, computed at decode time.
  final ViMetafileFrame frame;

  int get boundsLeft => _view.getInt32(_boundsLeft.offset, Endian.little);

  int get boundsTop => _view.getInt32(_boundsTop.offset, Endian.little);

  int get boundsRight => _view.getInt32(_boundsRight.offset, Endian.little);

  int get boundsBottom => _view.getInt32(_boundsBottom.offset, Endian.little);

  Uint8List serialize() => bytes;
}

ViEmfMetafile decodeEmf(Uint8List bytes) {
  assert(bytes.length >= _minHeaderBytes, 'EMF starts with a 48-byte or longer header record');
  final view = ByteData.sublistView(bytes);
  assert(view.getUint32(_headerType.offset, Endian.little) == _emrHeader, 'the first record is EMR_HEADER');
  assert(view.getUint32(_signature.offset, Endian.little) == _emfSignature, 'the header carries the EMF signature');
  final frame = _frameEmf(bytes, view);
  assert(frame != null, 'the records tile to EMR_EOF at the end of the payload');
  return ViEmfMetafile._(bytes, frame!);
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

ViMetafileFrame? _frameEmf(Uint8List payload, ByteData v) {
  var model = 0;
  var copied = 0;
  var pos = 0;
  var records = 0;
  while (pos + _recordHeaderBytes <= payload.length) {
    final iType = v.getUint32(pos, Endian.little);
    final nSize = v.getUint32(pos + 4, Endian.little);
    if (nSize < _recordHeaderBytes || (nSize & 3) != 0 || pos + nSize > payload.length) return null;
    final paramLen = nSize - _recordHeaderBytes;
    final modelParam = _emfModelParamBytes(iType, paramLen);
    model += _recordHeaderBytes + modelParam;
    copied += paramLen - modelParam;
    pos += nSize;
    records++;
    if (iType == _emrEof) {
      if (pos != payload.length) return null;
      return ViMetafileFrame(modelBytes: model, copiedBytes: copied, elementCount: records);
    }
  }
  return null;
}
