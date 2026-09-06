import 'dart:typed_data';

class ViTypeMap {
  const ViTypeMap({
    required this.rawLength,
    required this.framesExactly,
    required this.indexShift,
    required this.entries,
  });

  final int rawLength;

  final bool framesExactly;

  final int indexShift;

  final List<int> entries;
}

typedef _Var = ({int value, int next, int width});

_Var? _readVar(Uint8List b, int off) {
  if (off + 2 > b.length) return null;
  final hi = (b[off] << 8) | b[off + 1];
  if ((hi & 0x8000) == 0) return (value: hi, next: off + 2, width: 2);
  if (off + 4 > b.length) return null;
  final lo = (b[off + 2] << 8) | b[off + 3];
  return (value: ((hi & 0x7fff) << 16) | lo, next: off + 4, width: 4);
}

void _writeVar(BytesBuilder out, int value, int width) {
  if (width == 2) {
    out.add([value >> 8, value & 0xff]);
  } else {
    final hi = 0x8000 | (value >> 16);
    out.add([hi >> 8, hi & 0xff, (value >> 8) & 0xff, value & 0xff]);
  }
}

ViTypeMap? decodeTypeMap(Uint8List bytes) {
  final c = _readVar(bytes, 0);
  if (c == null) return null;
  final count = c.value;
  var off = c.next;
  var indexShift = 0;
  if (count > 0) {
    final s = _readVar(bytes, off);
    if (s == null) {
      return ViTypeMap(rawLength: bytes.length, framesExactly: false, indexShift: 0, entries: const []);
    }
    indexShift = s.value;
    off = s.next;
  }
  final entries = <int>[];
  var ran = true;
  for (var i = 0; i < count; i++) {
    final e = _readVar(bytes, off);
    if (e == null) {
      ran = false;
      break;
    }
    entries.add(e.value);
    off = e.next;
  }
  return ViTypeMap(
    rawLength: bytes.length,
    framesExactly: ran && off == bytes.length,
    indexShift: indexShift,
    entries: entries,
  );
}

bool typeMapFrames(Uint8List body) {
  final c = _readVar(body, 0);
  if (c == null) return false;
  final count = c.value;
  var off = c.next;
  if (count > 0) {
    final s = _readVar(body, off);
    if (s == null) return false;
    off = s.next;
  }
  for (var i = 0; i < count; i++) {
    final e = _readVar(body, off);
    if (e == null) return false;
    off = e.next;
  }
  return off == body.length;
}

Uint8List? reserializeTypeMap(Uint8List body) {
  final c = _readVar(body, 0);
  if (c == null) return null;
  final count = c.value;
  final out = BytesBuilder(copy: false);
  _writeVar(out, c.value, c.width);
  var off = c.next;
  if (count > 0) {
    final s = _readVar(body, off);
    if (s == null) return null;
    _writeVar(out, s.value, s.width);
    off = s.next;
  }
  for (var i = 0; i < count; i++) {
    final e = _readVar(body, off);
    if (e == null) return null;
    _writeVar(out, e.value, e.width);
    off = e.next;
  }
  if (off != body.length) return null;
  return out.toBytes();
}

const int kTypeMapHasSaveData = 1 << 13;
