import 'dart:typed_data';

class ViCompiledCode {
  const ViCompiledCode({
    required this.flags,
    required this.architecture,
    required this.codeSize,
    required this.bodyLength,
  });

  final int flags;

  final String architecture;

  final int codeSize;

  final int bodyLength;
}

ViCompiledCode? decodeCompiledCode(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final view = ByteData.sublistView(bytes);
  return ViCompiledCode(
    flags: view.getUint32(0),
    architecture: String.fromCharCodes(bytes.sublist(4, 8)),
    codeSize: view.getUint32(8, Endian.little),
    bodyLength: bytes.length - 16,
  );
}

class ViConnectorPaneMap {
  const ViConnectorPaneMap({required this.terminals});

  final List<int?> terminals;

  int get terminalCount => terminals.length;
  int get assignedCount => terminals.where((t) => t != null).length;

  Uint8List serialize() {
    final out = Uint8List(2 + 2 * terminals.length);
    out[0] = terminals.length & 0xff;
    out[1] = (terminals.length >> 8) & 0xff;
    for (var i = 0; i < terminals.length; i++) {
      final value = terminals[i] ?? 0xFFFF;
      out[2 + 2 * i] = value & 0xff;
      out[3 + 2 * i] = (value >> 8) & 0xff;
    }
    return out;
  }
}

ViConnectorPaneMap? decodeConnectorPaneMap(Uint8List bytes) {
  if (bytes.length < 2) return null;
  final count = bytes[0] | (bytes[1] << 8);
  if (2 + 2 * count != bytes.length) return null;
  final terminals = <int?>[];
  for (var i = 0; i < count; i++) {
    final value = bytes[2 + 2 * i] | (bytes[3 + 2 * i] << 8);
    terminals.add(value == 0xFFFF ? null : value);
  }
  return ViConnectorPaneMap(terminals: terminals);
}

class ViBookmarkEntry {
  const ViBookmarkEntry({required this.wordA, required this.wordB, required this.text});

  final int? wordA;

  final int wordB;

  final Uint8List text;
}

class ViBookmarkList {
  const ViBookmarkList({required this.tableA, required this.tableB});

  final List<ViBookmarkEntry> tableA;

  final List<ViBookmarkEntry> tableB;

  int get declaredCount => tableA.length;

  bool get isEmpty => tableA.isEmpty && tableB.isEmpty;

  List<String> get texts => [
    for (final e in [...tableA, ...tableB])
      if (_printable(e.text)) String.fromCharCodes(e.text),
  ];

  Uint8List serialize() {
    var n = 8;
    for (final e in tableA) {
      n += 12 + e.text.length;
    }
    for (final e in tableB) {
      n += 8 + e.text.length;
    }
    final out = Uint8List(n);
    final d = ByteData.sublistView(out);
    var pos = 0;
    d.setUint32(pos, tableA.length);
    pos += 4;
    for (final e in tableA) {
      d.setUint32(pos, e.wordA ?? 0);
      d.setUint32(pos + 4, e.wordB);
      d.setUint32(pos + 8, e.text.length);
      pos += 12;
      out.setRange(pos, pos + e.text.length, e.text);
      pos += e.text.length;
    }
    d.setUint32(pos, tableB.length);
    pos += 4;
    for (final e in tableB) {
      d.setUint32(pos, e.wordB);
      d.setUint32(pos + 4, e.text.length);
      pos += 8;
      out.setRange(pos, pos + e.text.length, e.text);
      pos += e.text.length;
    }
    return out;
  }
}

bool _printable(Uint8List b) {
  if (b.isEmpty) return false;
  for (final c in b) {
    if ((c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) || c >= 0x7f) return false;
  }
  return true;
}

ViBookmarkList? decodeBookmarkList(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final view = ByteData.sublistView(bytes);
  var pos = 0;
  List<ViBookmarkEntry>? readTable(bool withWordA) {
    if (pos + 4 > bytes.length) return null;
    final count = view.getUint32(pos);
    pos += 4;
    if (count > 100000) return null;
    final entries = <ViBookmarkEntry>[];
    for (var i = 0; i < count; i++) {
      final head = withWordA ? 12 : 8;
      if (pos + head > bytes.length) return null;
      final int? a = withWordA ? view.getUint32(pos) : null;
      final b = view.getUint32(pos + (withWordA ? 4 : 0));
      final len = view.getUint32(pos + head - 4);
      pos += head;
      if (len > bytes.length - pos) return null;
      entries.add(ViBookmarkEntry(wordA: a, wordB: b, text: Uint8List.sublistView(bytes, pos, pos + len)));
      pos += len;
    }
    return entries;
  }

  final tableA = readTable(true);
  if (tableA == null) return null;
  final tableB = readTable(false);
  if (tableB == null || pos != bytes.length) return null;
  return ViBookmarkList(tableA: tableA, tableB: tableB);
}

class ViOffsetTable {
  const ViOffsetTable({required this.offsets});
  final List<int> offsets;

  Uint8List serialize() {
    final out = Uint8List(offsets.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < offsets.length; i++) {
      d.setUint32(i * 4, offsets[i]);
    }
    return out;
  }
}

ViOffsetTable? decodeOffsetTable(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final view = ByteData.sublistView(bytes);
  final offsets = <int>[];
  var previous = -1;
  for (var pos = 0; pos < bytes.length; pos += 4) {
    final value = view.getUint32(pos);
    if (value < previous) return null;
    previous = value;
    offsets.add(value);
  }
  return ViOffsetTable(offsets: offsets);
}

class ViPngImage {
  const ViPngImage({required this.width, required this.height, required this.byteLength});
  final int width;
  final int height;
  final int byteLength;
}

const _pngMagic = [0x89, 0x50, 0x4e, 0x47];

ViPngImage? decodePngEnvelope(Uint8List bytes, [int start = 0]) {
  if (start + 24 > bytes.length) return null;
  for (var i = 0; i < 4; i++) {
    if (bytes[start + i] != _pngMagic[i]) return null;
  }
  if (String.fromCharCodes(bytes.sublist(start + 12, start + 16)) != 'IHDR') return null;
  final view = ByteData.sublistView(bytes);
  return ViPngImage(
    width: view.getUint32(start + 16),
    height: view.getUint32(start + 20),
    byteLength: bytes.length - start,
  );
}

class ViDataSpaceImage {
  const ViDataSpaceImage({required this.headerWords, required this.pngOffset, required this.png});

  final List<int> headerWords;

  final int? pngOffset;

  final ViPngImage? png;
}

ViDataSpaceImage? decodeDataSpaceImage(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0) != 0) return null;
  final headerWords = [for (var i = 0; i < 4; i++) view.getUint16(4 + 2 * i)];
  int? pngOffset;
  for (var pos = 0; pos + 4 <= bytes.length; pos++) {
    if (bytes[pos] == 0x89 && bytes[pos + 1] == 0x50 && bytes[pos + 2] == 0x4e && bytes[pos + 3] == 0x47) {
      pngOffset = pos;
      break;
    }
  }
  return ViDataSpaceImage(
    headerWords: headerWords,
    pngOffset: pngOffset,
    png: pngOffset == null ? null : decodePngEnvelope(bytes, pngOffset),
  );
}

class ViGcdiRecord {
  const ViGcdiRecord({required this.value, required this.payloadLength});
  final int value;
  final int payloadLength;
}

ViGcdiRecord? decodeGcdiRecord(Uint8List bytes) {
  if (bytes.length < 5 || bytes[4] != 0x01) return null;
  return ViGcdiRecord(
    value: ByteData.sublistView(bytes).getUint32(0),
    payloadLength: bytes.length - 5,
  );
}

class ViKeyValueTable {
  const ViKeyValueTable({required this.entries});

  final List<(Uint8List, Uint8List)> entries;

  Uint8List serialize() {
    var n = 4;
    for (final (k, v) in entries) {
      n += 8 + k.length + v.length;
    }
    final out = Uint8List(n);
    final d = ByteData.sublistView(out);
    d.setUint32(0, entries.length);
    var pos = 4;
    for (final (k, v) in entries) {
      d.setUint32(pos, k.length);
      pos += 4;
      out.setRange(pos, pos + k.length, k);
      pos += k.length;
      d.setUint32(pos, v.length);
      pos += 4;
      out.setRange(pos, pos + v.length, v);
      pos += v.length;
    }
    return out;
  }
}

ViKeyValueTable? decodeKeyValueTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final d = ByteData.sublistView(bytes);
  final count = d.getUint32(0);
  if (count > 100000) return null;
  var pos = 4;
  final entries = <(Uint8List, Uint8List)>[];
  for (var i = 0; i < count; i++) {
    final runs = <Uint8List>[];
    for (var f = 0; f < 2; f++) {
      if (pos + 4 > bytes.length) return null;
      final len = d.getUint32(pos);
      pos += 4;
      if (len > bytes.length - pos) return null;
      runs.add(Uint8List.sublistView(bytes, pos, pos + len));
      pos += len;
    }
    entries.add((runs[0], runs[1]));
  }
  if (pos != bytes.length) return null;
  return ViKeyValueTable(entries: entries);
}

class ViPascalStringTable {
  const ViPascalStringTable({required this.strings});

  final List<Uint8List> strings;

  List<String> get texts => [
    for (final s in strings)
      if (_printable(s)) String.fromCharCodes(s),
  ];

  Uint8List serialize() {
    var n = 4;
    for (final s in strings) {
      n += 1 + s.length;
    }
    final out = Uint8List(n);
    ByteData.sublistView(out).setUint32(0, strings.length);
    var pos = 4;
    for (final s in strings) {
      out[pos++] = s.length & 0xff;
      out.setRange(pos, pos + s.length, s);
      pos += s.length;
    }
    return out;
  }
}

ViPascalStringTable? decodePascalStringTable(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final count = ByteData.sublistView(bytes).getUint32(0);
  if (count > 100000) return null;
  var pos = 4;
  final strings = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    if (pos >= bytes.length) return null;
    final len = bytes[pos++];
    if (pos + len > bytes.length) return null;
    strings.add(Uint8List.sublistView(bytes, pos, pos + len));
    pos += len;
  }
  if (pos != bytes.length) return null;
  return ViPascalStringTable(strings: strings);
}
