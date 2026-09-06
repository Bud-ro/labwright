import 'dart:typed_data';

const _ftabHeaderLen = 12;

const _ftabRecordLen = 16;

class ViFontEntry {
  const ViFontEntry({
    required this.nameOffset,
    required this.size,
    required this.flagsByte,
    required this.styleFlags,
    required this.weight,
    required this.resolvedSize,
    required this.metricA,
    required this.metricB,
    required this.name,
  });

  final int nameOffset;

  final int size;

  final int flagsByte;

  final int styleFlags;

  final int weight;

  final int resolvedSize;

  final int metricA;

  final int metricB;

  final String name;

  static const int sizeUnset = 0x8000;

  static const int weightBold = 1000;

  bool get isBold => weight == weightBold;

  bool get isPredefinedRef => name.length == 1 && name.codeUnitAt(0) >= 0x30 && name.codeUnitAt(0) <= 0x32;
}

class ViFontTable {
  const ViFontTable({
    required this.rawLength,
    required this.version,
    required this.headerWords,
    required this.fontCount,
    required this.nameTableOffset,
    required this.metrics,
    required this.nameBytes,
    required this.names,
    required this.entries,
    required this.nameTableComplete,
  });

  final int rawLength;

  final int version;

  final List<int> headerWords;

  final int fontCount;

  final int nameTableOffset;

  final Uint8List metrics;

  final Uint8List nameBytes;

  final List<String> names;

  final List<ViFontEntry> entries;

  final bool nameTableComplete;

  /// Run font ids index past the three leading predefined-font slots.
  ViFontEntry? entryForRunFontId(int fontId) {
    final index = fontId + 3;
    return index >= 0 && index < entries.length ? entries[index] : null;
  }

  Uint8List serialize() {
    final out = Uint8List(_ftabHeaderLen + metrics.length + nameBytes.length);
    final d = ByteData.sublistView(out);
    d.setUint16(0, version);
    d.setUint16(2, headerWords.isNotEmpty ? headerWords[0] : 0);
    d.setUint16(4, headerWords.length > 1 ? headerWords[1] : 0);
    d.setUint16(6, fontCount);
    d.setUint32(8, nameTableOffset);
    out.setRange(_ftabHeaderLen, _ftabHeaderLen + metrics.length, metrics);
    out.setRange(_ftabHeaderLen + metrics.length, out.length, nameBytes);
    return out;
  }
}

ViFontTable? decodeFontTable(Uint8List bytes) {
  if (bytes.length < _ftabHeaderLen) return null;
  final bd = ByteData.sublistView(bytes);
  final version = bd.getUint16(0);
  final headerWords = [bd.getUint16(2), bd.getUint16(4)];
  final fontCount = bd.getUint16(6);
  final nameOff = bd.getUint32(8);
  final inRange = nameOff >= _ftabHeaderLen && nameOff <= bytes.length;
  final metricsEnd = inRange ? nameOff : _ftabHeaderLen;
  final names = <String>[];
  var pos = nameOff;
  var complete = inRange;
  for (var i = 0; i < fontCount; i++) {
    if (pos >= bytes.length) {
      complete = false;
      break;
    }
    final len = bytes[pos++];
    if (pos + len > bytes.length) {
      complete = false;
      break;
    }
    names.add(String.fromCharCodes(bytes, pos, pos + len));
    pos += len;
  }
  if (complete && pos != bytes.length) complete = false;
  const recordsStart = _ftabHeaderLen - 4;
  final entries = <ViFontEntry>[];
  if (complete && names.length == fontCount && nameOff == recordsStart + fontCount * _ftabRecordLen) {
    for (var i = 0; i < fontCount; i++) {
      final off = recordsStart + i * _ftabRecordLen;
      entries.add(
        ViFontEntry(
          nameOffset: bd.getUint32(off),
          size: bd.getUint16(off + 4),
          flagsByte: bd.getUint8(off + 6),
          styleFlags: bd.getUint8(off + 7),
          weight: bd.getUint16(off + 8),
          resolvedSize: bd.getUint16(off + 10),
          metricA: bd.getUint16(off + 12),
          metricB: bd.getUint16(off + 14),
          name: names[i],
        ),
      );
    }
  }
  return ViFontTable(
    rawLength: bytes.length,
    version: version,
    headerWords: headerWords,
    fontCount: fontCount,
    nameTableOffset: nameOff,
    metrics: Uint8List.sublistView(bytes, _ftabHeaderLen, metricsEnd),
    nameBytes: Uint8List.sublistView(bytes, inRange ? nameOff : bytes.length),
    names: names,
    entries: entries,
    nameTableComplete: complete,
  );
}
