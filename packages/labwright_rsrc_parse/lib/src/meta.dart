import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

class ViVersionInfo {
  const ViVersionInfo({this.version, this.title});

  final String? version;

  final String? title;
}

final RegExp _versionPattern = RegExp(r'^\d{1,2}\.\d');

ViVersionInfo decodeVersion(Uint8List viBytes) => versionFromSections(readViSections(viBytes));

ViVersionInfo versionFromSections(Iterable<ViSection> sections) {
  String? version, title;
  for (final section in sections) {
    if (section.tag != 'vers') continue;
    for (final str in _pascalStrings(section.bytes)) {
      if (version == null && _versionPattern.hasMatch(str)) version = str;
    }
    title ??= _vidsTitle(section.bytes);
  }
  return ViVersionInfo(version: version, title: title);
}

class BlockComponent {
  const BlockComponent({
    required this.tag,
    required this.sectionCount,
    required this.rawBytes,
    required this.decompressedBytes,
    required this.compressed,
  });

  final String tag;

  final int sectionCount;

  final int rawBytes;

  final int decompressedBytes;

  final bool compressed;
}

List<BlockComponent> blockComponents(Uint8List viBytes) => componentsFromDecoded(decodeSections(viBytes));

List<BlockComponent> componentsFromDecoded(Iterable<DecodedSection> decoded) {
  final byTag = <String, List<DecodedSection>>{};
  for (final decodedSection in decoded) {
    (byTag[decodedSection.tag] ??= <DecodedSection>[]).add(decodedSection);
  }
  final out = [
    for (final entry in byTag.entries)
      BlockComponent(
        tag: entry.key,
        sectionCount: entry.value.length,
        rawBytes: entry.value.fold<int>(0, (a, d) => a + d.section.bytes.length),
        decompressedBytes: entry.value.fold<int>(0, (a, d) => a + d.bytes.length),
        compressed: entry.value.any((d) => d.wasCompressed),
      ),
  ];
  out.sort((a, b) => b.decompressedBytes.compareTo(a.decompressedBytes));
  return out;
}

class HeapStringTable {
  const HeapStringTable({
    required this.sectionTag,
    required this.offset,
    required this.strings,
    this.framed = false,
  });

  final String sectionTag;

  final int offset;

  final List<String> strings;

  final bool framed;
}

List<String> extractHeapStrings(Uint8List viBytes, {int minLength = 4}) =>
    heapStringsFromDecoded(decodeSections(viBytes), minLength: minLength);

List<HeapStringTable> heapStringTables(Uint8List viBytes, {int minLength = 4, int minRun = 2}) =>
    heapStringTablesFromDecoded(decodeSections(viBytes), minLength: minLength, minRun: minRun);

List<HeapStringTable> heapStringTablesFromDecoded(
  Iterable<DecodedSection> decoded, {
  int minLength = 4,
  int minRun = 2,
}) {
  final out = <HeapStringTable>[];

  for (final decodedSection in decoded) {
    final bytes = decodedSection.bytes;
    final byteCount = bytes.length;
    var i = 0;
    var runStart = -1;
    final run = <String>[];

    void emit(List<String> raw, int offset, {bool framed = false}) {
      final seen = <String>{};
      final keep = [
        for (final text in raw)
          if (text.length >= minLength && _looksWordy(text) && seen.add(text)) text,
      ];
      if (keep.isNotEmpty) {
        out.add(HeapStringTable(sectionTag: decodedSection.tag, offset: offset, strings: keep, framed: framed));
      }
    }

    void flushRun() {
      if (run.length >= minRun) emit(run, runStart);
      run.clear();
      runStart = -1;
    }

    while (i < byteCount) {
      final framed = _tryFramedTable(bytes, i);
      if (framed != null) {
        flushRun();
        emit(framed.strings, i + framed.headerLen, framed: true);
        i += framed.consumed;
        continue;
      }
      final len = bytes[i];
      if (len >= 1 && i + 1 + len <= byteCount && _allPrintable(bytes, i + 1, len)) {
        if (run.isEmpty) runStart = i;
        run.add(_pascalChars(bytes, i + 1, len));
        i += 1 + len;
      } else {
        flushRun();
        i++;
      }
    }
    flushRun();
  }
  return out;
}

({List<String> strings, int headerLen, int consumed})? _tryFramedTable(Uint8List bytes, int start) {
  final byteCount = bytes.length;
  if (start + 3 > byteCount || bytes[start] != kHeapRecordPrefix || bytes[start + 1] != HeapOpcode.stringTable.byte) {
    return null;
  }
  final int headerLen, payloadLen;
  if (bytes[start + 2] == 0xff) {
    if (start + 5 > byteCount) return null;
    headerLen = 5;
    payloadLen = ByteData.sublistView(bytes).getUint16(start + 3);
  } else {
    headerLen = 3;
    payloadLen = bytes[start + 2];
  }
  if (payloadLen < 2 || start + headerLen + payloadLen > byteCount) return null;
  final strs = _packedPascals(bytes, start + headerLen, payloadLen);
  if (strs == null || strs.length < 2) return null;
  return (strings: strs, headerLen: headerLen, consumed: headerLen + payloadLen);
}

List<String>? _packedPascals(Uint8List bytes, int start, int len) {
  final end = start + len;
  final out = <String>[];
  var i = start;
  while (i < end) {
    final len = bytes[i];
    if (len == 0 || i + 1 + len > end || !_allPrintable(bytes, i + 1, len)) return null;
    out.add(_pascalChars(bytes, i + 1, len));
    i += 1 + len;
  }
  return out;
}

List<String> heapStringsFromDecoded(Iterable<DecodedSection> decoded, {int minLength = 4, int minRun = 2}) {
  final seen = <String>{};
  return [
    for (final table in heapStringTablesFromDecoded(decoded, minLength: minLength, minRun: minRun))
      for (final text in table.strings)
        if (seen.add(text)) text,
  ];
}

String _pascalChars(Uint8List bytes, int start, int len) => String.fromCharCodes(bytes.sublist(start, start + len));

bool _allPrintable(Uint8List bytes, int start, int len) {
  for (var j = start; j < start + len; j++) {
    if (bytes[j] < 32 || bytes[j] >= 127) return false;
  }
  return true;
}

List<String> _pascalStrings(Uint8List bytes) {
  final out = <String>[];
  var i = 0;
  while (i < bytes.length) {
    final len = bytes[i];
    if (len >= 1 && len <= 120 && i + 1 + len <= bytes.length && _allPrintable(bytes, i + 1, len)) {
      out.add(_pascalChars(bytes, i + 1, len));
      i += 1 + len;
      continue;
    }
    i++;
  }
  return out;
}

bool _isTextByte(int byte) => byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127);

bool _looksWordy(String text) =>
    text.codeUnits.any((byte) => (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a));

String? cpc2Description(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag != 'CPC2') continue;
    final bytes = section.bytes;
    if (bytes.length < 5) continue;
    final len = ByteData.sublistView(bytes).getUint32(0);
    if (len == 0 || 4 + len > bytes.length) continue;
    final ok = bytes.getRange(4, 4 + len).every(_isTextByte);
    if (ok) return String.fromCharCodes(bytes.sublist(4, 4 + len));
  }
  return null;
}

String? _vidsTitle(Uint8List bytes) {
  for (var i = 0; i + 5 <= bytes.length; i++) {
    if (bytes[i] == 0x56 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x44 && bytes[i + 3] == 0x53) {
      final len = bytes[i + 4];
      if (len > 0 && i + 5 + len <= bytes.length && _allPrintable(bytes, i + 5, len)) {
        return _pascalChars(bytes, i + 5, len);
      }
    }
  }
  return null;
}
