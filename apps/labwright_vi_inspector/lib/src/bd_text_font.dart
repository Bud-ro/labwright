import 'dart:io';

import 'package:flutter/services.dart';

String bdTextFontFamily = 'Selawik';

const String kBdSystemUiFamily = 'BdSystemUi';

const int kBdTextPpem = 12;

final Map<int, int> _hintedRegular = Map.of(_kFallbackHintedRegular);
final Map<int, int> _hintedBold = Map.of(_kFallbackHintedBold);

const Map<int, int> _kFallbackHintedRegular = {0x43: 8, 0x6d: 11}; // C m
const Map<int, int> _kFallbackHintedBold = {0x65: 7}; // e

int? bdHintedAdvance(int rune, {required bool bold}) =>
    (bold ? _hintedBold : _hintedRegular)[rune];

double bdEmForCellHeight(int cellPx) =>
    (cellPx.clamp(4, 96) * 4 / 5).floorToDouble();

Future<bool> loadSystemUiFont() async {
  final dirs = [
    Platform.environment['LW_SEGOE_DIR'],
    r'C:\Windows\Fonts',
    '/mnt/c/Windows/Fonts',
  ];
  for (final dir in dirs) {
    if (dir == null) continue;
    final sep = dir.contains('\\') ? '\\' : '/';
    final regular = File('$dir${sep}segoeui.ttf');
    final bold = File('$dir${sep}segoeuib.ttf');
    if (!regular.existsSync() || !bold.existsSync()) continue;
    final regularBytes = regular.readAsBytesSync();
    final boldBytes = bold.readAsBytesSync();
    final loader = FontLoader(kBdSystemUiFamily)
      ..addFont(Future.value(ByteData.sublistView(regularBytes)))
      ..addFont(Future.value(ByteData.sublistView(boldBytes)));
    await loader.load();
    _adoptHdmx(regularBytes, _hintedRegular);
    _adoptHdmx(boldBytes, _hintedBold);
    bdTextFontFamily = kBdSystemUiFamily;
    return true;
  }
  return false;
}

void _adoptHdmx(Uint8List ttf, Map<int, int> into) {
  final face = _Sfnt.tryParse(ttf);
  final record = face?.hdmxRecord(kBdTextPpem);
  if (face == null || record == null) return;
  into.clear();
  final upem = face.unitsPerEm;
  face.forEachCmapEntry((rune, glyph) {
    if (glyph >= record.length) return;
    final hinted = record[glyph];
    if (hinted != (face.linearAdvance(glyph) * kBdTextPpem / upem).round()) {
      into[rune] = hinted;
    }
  });
}

class _Sfnt {
  _Sfnt._(this._bytes, this._data, this._tables);

  final Uint8List _bytes;
  final ByteData _data;
  final Map<String, int> _tables;

  static const Set<int> _sfntVersions = {0x00010000, 0x74727565, 0x4f54544f};

  static _Sfnt? tryParse(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final data = ByteData.sublistView(bytes);
    if (!_sfntVersions.contains(data.getUint32(0))) return null;
    final numTables = data.getUint16(4);
    if (12 + 16 * numTables > bytes.length) return null;
    final tables = <String, int>{};
    for (var i = 0; i < numTables; i++) {
      final at = 12 + 16 * i;
      final offset = data.getUint32(at + 8);
      if (offset >= bytes.length) continue;
      tables[String.fromCharCodes(bytes, at, at + 4)] = offset;
    }
    const needed = ['maxp', 'head', 'hhea', 'hmtx', 'cmap'];
    if (needed.any((t) => !tables.containsKey(t))) return null;
    return _Sfnt._(bytes, data, tables);
  }

  int get _numGlyphs => _data.getUint16(_tables['maxp']! + 4);

  int get unitsPerEm => _data.getUint16(_tables['head']! + 18);

  Uint8List? hdmxRecord(int ppem) {
    final table = _tables['hdmx'];
    if (table == null) return null;
    final count = _data.getUint16(table + 2);
    final recordSize = _data.getUint32(table + 4);
    for (var i = 0; i < count; i++) {
      final at = table + 8 + i * recordSize;
      if (at + 2 + _numGlyphs > _bytes.length) return null;
      if (_data.getUint8(at) == ppem) {
        return Uint8List.sublistView(_bytes, at + 2, at + 2 + _numGlyphs);
      }
    }
    return null;
  }

  int linearAdvance(int glyph) {
    final numH = _data.getUint16(_tables['hhea']! + 34);
    final at = _tables['hmtx']! + 4 * (glyph < numH ? glyph : numH - 1);
    return _data.getUint16(at);
  }

  void forEachCmapEntry(void Function(int rune, int glyph) visit) {
    final table = _tables['cmap']!;
    final subtables = _data.getUint16(table + 2);
    int? best;
    for (var i = 0; i < subtables; i++) {
      final at = table + 4 + 8 * i;
      final platform = _data.getUint16(at);
      final encoding = _data.getUint16(at + 2);
      final offset = table + _data.getUint32(at + 4);
      if (platform == 3 && encoding == 1) best = offset;
      best ??= offset;
    }
    if (best == null || best + 14 > _bytes.length) return;
    if (_data.getUint16(best) != 4) return;
    final segX2 = _data.getUint16(best + 6);
    final ends = best + 14;
    final starts = ends + segX2 + 2;
    final deltas = starts + segX2;
    final ranges = deltas + segX2;
    for (var seg = 0; seg < segX2 ~/ 2; seg++) {
      final end = _data.getUint16(ends + 2 * seg);
      final start = _data.getUint16(starts + 2 * seg);
      final delta = _data.getInt16(deltas + 2 * seg);
      final rangeOffset = _data.getUint16(ranges + 2 * seg);
      for (var rune = start; rune <= end && rune != 0xFFFF; rune++) {
        int glyph;
        if (rangeOffset == 0) {
          glyph = (rune + delta) & 0xFFFF;
        } else {
          final at = ranges + 2 * seg + rangeOffset + 2 * (rune - start);
          if (at + 2 > _bytes.length) continue;
          glyph = _data.getUint16(at);
          if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
        }
        if (glyph != 0) visit(rune, glyph);
      }
    }
  }
}
