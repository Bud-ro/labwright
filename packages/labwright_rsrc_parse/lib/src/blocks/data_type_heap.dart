import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

class ViDataTypeHeap {
  const ViDataTypeHeap({
    required this.rawLength,
    required this.heapTypeCount,
    required this.firstTopLevelIndex,
    required this.isExtended,
    required this.names,
  });

  final int rawLength;

  final int heapTypeCount;

  final int firstTopLevelIndex;

  final bool isExtended;

  final List<String> names;

  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  /// A heap typeDescIndex is 1-based within the run that starts at the 1-based [firstTopLevelIndex].
  int get viTypeIndexBase => firstTopLevelIndex - 2;

  Uint8List serialize() {
    final out = Uint8List(4);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, heapTypeCount);
    bd.setUint16(2, firstTopLevelIndex);
    return out;
  }
}

ViDataTypeHeap? decodeDataTypeHeap(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final extended = bytes.length > 4;
  return ViDataTypeHeap(
    rawLength: bytes.length,
    heapTypeCount: (bytes[0] << 8) | bytes[1],
    firstTopLevelIndex: (bytes[2] << 8) | bytes[3],
    isExtended: extended,
    names: extended ? _scanNames(bytes, 4) : const [],
  );
}

List<String> _scanNames(Uint8List bytes, int from) {
  final out = <String>[];
  var pos = from;
  while (pos + 3 < bytes.length) {
    final len = bytes[pos + 2];
    final start = pos + 3;
    if (bytes[pos] == 0x40 &&
        bytes[pos + 1] <= 0x7f &&
        len > 0 &&
        start + len <= bytes.length &&
        _printable(bytes, start, start + len)) {
      out.add(String.fromCharCodes(bytes, start, start + len));
      pos = start + len;
      continue;
    }
    pos++;
  }
  return out;
}

bool _printable(Uint8List bytes, int start, int end) =>
    bytes.getRange(start, end).every((c) => c == 0x09 || c == 0x0a || c == 0x0d || (c >= 0x20 && c < 0x7f));
