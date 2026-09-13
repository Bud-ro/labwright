import 'dart:typed_data';

class ViIdTable {
  const ViIdTable({required this.rawLength, required this.count, required this.entries});

  final int rawLength;

  final int count;

  final List<int> entries;

  Uint8List serialize() {
    final out = Uint8List(4 + 4 * entries.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, count);
    for (var i = 0; i < entries.length; i++) {
      bd.setUint32(4 + 4 * i, entries[i]);
    }
    return out;
  }
}

ViIdTable? decodeIdTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(0);
  final available = (bytes.length - 4) ~/ 4;
  final entryCount = count.clamp(0, available);
  return ViIdTable(
    rawLength: bytes.length,
    count: count,
    entries: [for (var i = 0; i < entryCount; i++) bd.getUint32(4 + 4 * i)],
  );
}
