import 'dart:typed_data';

class ViTagEntry {
  const ViTagEntry({required this.name, required this.payload, this.nested = false});

  final String name;

  final Uint8List payload;

  final bool nested;

  int get payloadLength => payload.length;
}

class ViTagStore {
  const ViTagStore({
    required this.declaredCount,
    required this.entries,
    required this.walkComplete,
  });

  final int declaredCount;

  final List<ViTagEntry> entries;

  final bool walkComplete;

  Uint8List serialize() {
    var size = 4;
    for (final e in entries) {
      size += 4 + e.name.length + (e.nested ? 0 : 4) + e.payload.length;
    }
    final out = Uint8List(size);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, declaredCount);
    var pos = 4;
    for (final e in entries) {
      bd.setUint32(pos, e.name.length);
      pos += 4;
      out.setRange(pos, pos + e.name.length, e.name.codeUnits);
      pos += e.name.length;
      if (!e.nested) {
        bd.setUint32(pos, e.payload.length);
        pos += 4;
      }
      out.setRange(pos, pos + e.payload.length, e.payload);
      pos += e.payload.length;
    }
    return out;
  }
}

final Uint8List _sourceOnlyTail = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x01, //
  0x00, 0x04, 0x00, 0x21, 0x00, 0x01, //
  0x00, 0x00, //
  0x01, 0x00, 0x00, 0x00, 0x00,
]);

const int _sourceOnlyLen = 21;

bool _validEntryHeader(Uint8List bytes, int off, int end) {
  if (off + 4 > end) return false;
  final nameLen = ByteData.sublistView(bytes).getUint32(off);
  if (nameLen < 1 || nameLen > 128 || off + 4 + nameLen > end) return false;
  for (var i = off + 4; i < off + 4 + nameLen; i++) {
    final b = bytes[i];
    if (b < 0x20 || b >= 0x7f) return false;
  }
  return true;
}

int? _nestedEntryEnd(Uint8List bytes, int s, int storeEnd) {
  if (s + 12 > storeEnd || bytes[s + 2] != 0x80) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(s + 4) == 1) {
    final fieldDescLen = view.getUint16(s + 8);
    final lenAt = s + 12 + fieldDescLen;
    if (lenAt + 4 <= storeEnd) {
      final contentLen = view.getUint32(lenAt);
      final end = lenAt + 4 + contentLen + 4;
      if (end <= storeEnd && _validEntryHeader(bytes, end, storeEnd)) return end;
    }
  }
  if (s + _sourceOnlyLen <= storeEnd) {
    var match = true;
    for (var i = 0; i < _sourceOnlyTail.length; i++) {
      if (bytes[s + 4 + i] != _sourceOnlyTail[i]) {
        match = false;
        break;
      }
    }
    if (match && _validEntryHeader(bytes, s + _sourceOnlyLen, storeEnd)) {
      return s + _sourceOnlyLen;
    }
  }
  return null;
}

ViTagStore? decodeTagStore(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final view = ByteData.sublistView(bytes);
  final declaredCount = view.getUint32(0);
  if (declaredCount > 65536) {
    return ViTagStore(declaredCount: declaredCount, entries: const [], walkComplete: false);
  }
  final entries = <ViTagEntry>[];
  var pos = 4;
  while (entries.length < declaredCount && pos + 4 <= bytes.length) {
    final nameLen = view.getUint32(pos);
    pos += 4;
    if (nameLen > 4096 || pos + nameLen > bytes.length) break;
    var printable = true;
    for (var i = pos; i < pos + nameLen; i++) {
      final byte = bytes[i];
      if (byte < 0x20 || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) break;
    final name = String.fromCharCodes(bytes.sublist(pos, pos + nameLen));
    pos += nameLen;
    if (pos + 4 > bytes.length) break;
    final payloadLen = view.getUint32(pos);
    if (payloadLen > bytes.length - pos - 4) {
      // A nested variant record carries no payload-length word.
      final isLast = entries.length == declaredCount - 1;
      final int end;
      if (isLast) {
        end = bytes.length;
      } else {
        final bounded = _nestedEntryEnd(bytes, pos, bytes.length);
        if (bounded == null) break;
        end = bounded;
      }
      entries.add(ViTagEntry(name: name, payload: Uint8List.sublistView(bytes, pos, end), nested: true));
      pos = end;
      continue;
    }
    pos += 4;
    if (payloadLen > bytes.length - pos) break;
    final payload = Uint8List.sublistView(bytes, pos, pos + payloadLen);
    pos += payloadLen;
    entries.add(ViTagEntry(name: name, payload: payload));
  }
  return ViTagStore(
    declaredCount: declaredCount,
    entries: entries,
    walkComplete: entries.length == declaredCount && pos == bytes.length,
  );
}
