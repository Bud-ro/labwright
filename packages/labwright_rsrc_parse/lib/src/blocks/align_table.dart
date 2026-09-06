import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;

class ViAlignEntry {
  const ViAlignEntry({required this.offset, required this.value, required this.kind});

  final int offset;

  final int value;

  final int kind;
}

class ViAlignTable {
  const ViAlignTable({required this.count, required this.entries});

  final int count;

  final List<ViAlignEntry> entries;

  static const BlockConfidence framingConfidence = BlockConfidence.confirmed;

  Uint8List serialize() {
    final out = Uint8List(4 + 9 * entries.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, count);
    var p = 4;
    for (final e in entries) {
      bd.setUint32(p, e.offset);
      bd.setUint32(p + 4, e.value);
      out[p + 8] = e.kind;
      p += 9;
    }
    return out;
  }
}

ViAlignTable? decodeAlignTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(0);
  final available = (bytes.length - 4) ~/ 9;
  final n = count.clamp(0, available);
  final entries = <ViAlignEntry>[
    for (var i = 0; i < n; i++)
      ViAlignEntry(
        offset: bd.getUint32(4 + 9 * i),
        value: bd.getUint32(4 + 9 * i + 4),
        kind: bytes[4 + 9 * i + 8],
      ),
  ];
  return ViAlignTable(count: count, entries: entries);
}
