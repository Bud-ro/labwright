/// ```text
///   [0]  u32le codeStart   offset of the machine code within the body
///   [4]  4cc   arch        target architecture: "i386", "m386", or "wx64"
///   [8]  u32le codeSize    size of the compiled machine code
///   [12] u32le reserved    0x103
///   [16] u32le flags
///   [20] 4cc   "code"      compiled-code chunk tag
///   [24…]      fixup + machine code  (opaque; machine code begins at codeStart)
///   [codeEnd]  4cc "CODE"  symbol-table chunk tag
///   …          symbol table
/// ```
/// ```text
///   [CODE] [3× u32le 0] [u32le selfOff == codeEnd]         (m386 stops here)
///          [u32le count] then count entries                 (i386)
///   [CODE] [u32le codeImageSize] [4× u32le 0]
///          [u32le selfOff == codeEnd] [u32le 0] [u32le count] then count entries  (wx64)
///   entry = [u32le nameLen] [nameLen bytes] [zero pad to a 4-byte boundary]
/// ```
library;

import 'dart:typed_data';

const int _reservedTag = 0x103;

int? _codeEndOffset(String arch) => switch (arch) {
  'i386' || 'm386' => 36,
  'wx64' => 40,
  _ => null,
};

class _Layout {
  _Layout({
    required this.arch,
    required this.codeEndOff,
    required this.codeEnd,
    required this.tableCountOff,
    required this.entriesOff,
    required this.entries,
  });

  final String arch;

  final int codeEndOff;

  final int codeEnd;

  final int tableCountOff;

  final int entriesOff;

  final List<List<int>> entries;
}

_Layout? _parse(Uint8List body) {
  if (body.length < 44) return null;
  final view = ByteData.sublistView(body);
  if (view.getUint32(12, Endian.little) != _reservedTag) return null;
  final arch = String.fromCharCodes(body, 4, 8);
  final codeEndOff = _codeEndOffset(arch);
  if (codeEndOff == null) return null;
  if (!_is4cc(body, 20, 'code')) return null;
  final codeEnd = view.getUint32(codeEndOff, Endian.little);
  if (codeEnd < 40 || codeEnd + 8 > body.length) return null;
  if (!_is4cc(body, codeEnd, 'CODE')) return null;

  if (arch == 'm386') {
    if (body.length - codeEnd != 20) return null;
    if (view.getUint32(codeEnd + 16, Endian.little) != codeEnd) return null;
    return _Layout(
      arch: arch,
      codeEndOff: codeEndOff,
      codeEnd: codeEnd,
      tableCountOff: -1,
      entriesOff: -1,
      entries: const [],
    );
  }

  final int selfOff, countOff, entriesOff;
  if (arch == 'i386') {
    if (codeEnd + 24 > body.length) return null;
    selfOff = codeEnd + 16;
    countOff = codeEnd + 20;
    entriesOff = codeEnd + 24;
  } else {
    if (codeEnd + 36 > body.length) return null;
    selfOff = codeEnd + 24;
    countOff = codeEnd + 32;
    entriesOff = codeEnd + 36;
  }
  if (view.getUint32(selfOff, Endian.little) != codeEnd) return null;
  final count = view.getUint32(countOff, Endian.little);
  if (count > 100000) return null;

  final entries = <List<int>>[];
  var pos = entriesOff;
  while (pos < body.length) {
    if (pos + 4 > body.length) return null;
    final len = view.getUint32(pos, Endian.little);
    if (len > 1 << 20) return null;
    final nameOff = pos + 4;
    final end = nameOff + ((len + 3) & ~3);
    if (end > body.length) return null;
    entries.add([pos, nameOff, end]);
    pos = end;
  }
  if (pos != body.length) return null;
  if (entries.length != count) return null;

  return _Layout(
    arch: arch,
    codeEndOff: codeEndOff,
    codeEnd: codeEnd,
    tableCountOff: countOff,
    entriesOff: entriesOff,
    entries: entries,
  );
}

bool _is4cc(Uint8List b, int at, String s) {
  if (at < 0 || at + 4 > b.length) return false;
  for (var i = 0; i < 4; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

void _copy(Uint8List out, Uint8List src, int start, int end) {
  if (end > start) out.setRange(start, end, src, start);
}

Uint8List? reserializeCompiledCode(Uint8List body) {
  final layout = _parse(body);
  if (layout == null) return null;
  final out = Uint8List(body.length);
  final src = ByteData.sublistView(body);
  final dst = ByteData.sublistView(out);

  dst.setUint32(0, src.getUint32(0, Endian.little), Endian.little);
  for (var i = 0; i < 4; i++) {
    out[4 + i] = body[4 + i];
  }
  dst.setUint32(8, src.getUint32(8, Endian.little), Endian.little);
  dst.setUint32(12, _reservedTag, Endian.little);
  dst.setUint32(16, src.getUint32(16, Endian.little), Endian.little);
  for (var i = 0; i < 4; i++) {
    out[20 + i] = 'code'.codeUnitAt(i);
  }

  _copy(out, body, 24, layout.codeEndOff);
  dst.setUint32(layout.codeEndOff, layout.codeEnd, Endian.little);
  _copy(out, body, layout.codeEndOff + 4, layout.codeEnd);

  for (var i = 0; i < 4; i++) {
    out[layout.codeEnd + i] = 'CODE'.codeUnitAt(i);
  }
  final headerEnd = layout.entriesOff < 0 ? body.length : layout.entriesOff;
  for (var off = layout.codeEnd + 4; off < headerEnd; off += 4) {
    dst.setUint32(off, src.getUint32(off, Endian.little), Endian.little);
  }
  for (final entry in layout.entries) {
    final lenOff = entry[0];
    final nameOff = entry[1];
    final end = entry[2];
    dst.setUint32(lenOff, src.getUint32(lenOff, Endian.little), Endian.little);
    _copy(out, body, nameOff, end);
  }

  return out;
}

bool compiledCodeFrames(Uint8List body) => _parse(body) != null;
