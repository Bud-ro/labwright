/// Windows-1252, the code page of `TOF1` pool strings.
///
/// Bytes below 0x80 and from 0xa0 up map to the same code point; 0x80–0x9f map through
/// [_windows1252High]. The five bytes Windows-1252 leaves unassigned (0x81, 0x8d, 0x8f, 0x90, 0x9d)
/// map to the C1 control of the same value, as Windows itself decodes them, so every byte
/// sequence decodes and encodes back unchanged.
library;

import 'dart:typed_data';

/// Code points of the bytes 0x80–0x9f, indexed by `byte - 0x80`.
const List<int> _windows1252High = [
  0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
  0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
];

const _highStart = 0x80;

const _highEnd = 0xa0;

const _byteLimit = 0x100;

final Map<int, int> _windows1252Encode = {
  for (var i = 0; i < _windows1252High.length; i++) _windows1252High[i]: _highStart + i,
};

/// Decodes `bytes[start, end)` as Windows-1252.
String decodeWindows1252(Uint8List bytes, int start, int end) {
  final units = Uint16List(end - start);
  for (var i = start; i < end; i++) {
    final byte = bytes[i];
    units[i - start] = byte >= _highStart && byte < _highEnd ? _windows1252High[byte - _highStart] : byte;
  }
  return String.fromCharCodes(units);
}

/// Encodes [text] as Windows-1252; null when it holds a character the code page lacks.
Uint8List? encodeWindows1252(String text) {
  final out = Uint8List(text.length);
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < _highStart || (unit >= _highEnd && unit < _byteLimit)) {
      out[i] = unit;
      continue;
    }
    final byte = _windows1252Encode[unit];
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
