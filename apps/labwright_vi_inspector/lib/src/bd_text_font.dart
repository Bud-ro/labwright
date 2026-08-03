import 'dart:io';

import 'package:flutter/services.dart';

/// The font family the block-diagram painter lays out and paints text with:
/// the bundled, metric-compatible Selawik by default, swapped to the host
/// system's own Windows UI face when [loadSystemUiFont] finds and registers
/// one.
String bdTextFontFamily = 'Selawik';

/// The registration name for the host system's UI face (see
/// [loadSystemUiFont]).
const String kBdSystemUiFamily = 'BdSystemUi';

/// The ppem the reference rasterizer set diagram text at: the capture
/// machine's classic GDI text output at the default UI size — a 12 px em
/// (15 px cell height, the reference's line pitch; value digits on its
/// exact 6 px advance pitch match the face's `hdmx` 12 ppem record and no
/// other).
const int kBdTextPpem = 12;

/// Per-glyph HINTED integer advances at [kBdTextPpem], keyed by rune, for
/// the glyphs whose hinted advance DIFFERS from the rounded linear one —
/// [bdHintedAdvance] returns null for every other glyph and the caller
/// falls back to rounding the engine-measured width.
///
/// GDI pens each glyph by its `hdmx` (Horizontal Device Metrics) advance —
/// the pre-hinted integer widths the face carries per ppem — not by
/// rounding the scaled linear advance. At 12 ppem the Windows UI face's
/// hdmx disagrees with rounded-linear on exactly three ASCII glyphs
/// (parsed from the face: regular `C` 7.430→8 and `m` 10.336→11; bold `e`
/// 6.492→7). The bundled Selawik is metric-compatible at the linear level
/// but carries no hdmx, so these deltas are seeded as the canonical
/// fallback — reference-measured too (crc8's `CRC-8` inks 32 px, which
/// only `C`=8 lays out). When [loadSystemUiFont] registers the host face,
/// its own parsed hdmx replaces the seed (byte-identical on a stock
/// install).
final Map<int, int> _hintedRegular = Map.of(_kFallbackHintedRegular);
final Map<int, int> _hintedBold = Map.of(_kFallbackHintedBold);

const Map<int, int> _kFallbackHintedRegular = {0x43: 8, 0x6d: 11}; // C m
const Map<int, int> _kFallbackHintedBold = {0x65: 7}; // e

/// The hinted integer advance of [rune] at [kBdTextPpem] when it differs
/// from the rounded linear advance, else null (round the measured width).
/// Only meaningful for text set at the default 12 em; other sizes keep
/// rounded-linear advances.
int? bdHintedAdvance(int rune, {required bool bold}) =>
    (bold ? _hintedBold : _hintedRegular)[rune];

/// The em size (px) the reference rasterizer sets for a font-table entry's
/// cell height [cellPx] (`ViFontEntry.resolvedSize` — GDI's positive
/// lfHeight, the character cell): the largest em whose hinted cell fits.
/// Measured against the references: cell 15 → 12 em (the default face:
/// 15 px line pitch, 6 px digit advances); cell 21 → 16 em
/// (crc32_lookup_table's heading ink runs 6 px SHORT of a linearly-scaled
/// 16.8 em and matches the 16 ppem advance sum). Between the measured
/// points the linear 4/5 ratio floors to the nearest whole em — hinted
/// cells only ever meet or exceed the linear estimate.
double bdEmForCellHeight(int cellPx) =>
    cellPx == 15 ? 12.0 : (cellPx * 4 / 5).floorToDouble();

/// Registers the host system's own Windows UI text face (`segoeui.ttf` +
/// `segoeuib.ttf`) for diagram text and prefers it over the bundled Selawik,
/// returning whether a face was found. The faces' `hdmx` tables at
/// [kBdTextPpem] replace the canonical hinted-advance seed ([bdHintedAdvance]).
///
/// Licensing: the face is read AT RUNTIME from the host's licensed Windows
/// installation and is never bundled, committed, or written anywhere —
/// redistributing the font is not licensed, while rendering with the copy
/// the user's own Windows install provides is. Probed locations: the
/// `LW_SEGOE_DIR` environment override, then the standard install font
/// directory (`C:\Windows\Fonts` natively; `/mnt/c/Windows/Fonts` under
/// WSL). Absent a face, the bundled Selawik stays in effect.
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
    if (!regular.existsSync()) continue;
    final regularBytes = regular.readAsBytesSync();
    final loader = FontLoader(kBdSystemUiFamily)
      ..addFont(Future.value(ByteData.sublistView(regularBytes)));
    _adoptHdmx(regularBytes, _hintedRegular);
    final bold = File('$dir${sep}segoeuib.ttf');
    if (bold.existsSync()) {
      final boldBytes = bold.readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(boldBytes)));
      _adoptHdmx(boldBytes, _hintedBold);
    }
    await loader.load();
    bdTextFontFamily = kBdSystemUiFamily;
    return true;
  }
  return false;
}

/// Replaces [into] with the rune→advance entries of [ttf]'s `hdmx` record
/// at [kBdTextPpem] that differ from the rounded linear (`hmtx`) advance —
/// the exact set [bdHintedAdvance] must override. No-op when the face
/// carries no such record (the canonical seed stays).
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

/// Minimal big-endian sfnt reader for the three tables the hinted-advance
/// law needs: `hdmx` (per-ppem integer advances), `cmap` (format-4
/// rune→glyph), `hmtx`/`hhea`/`maxp`/`head` (linear advances + framing).
class _Sfnt {
  _Sfnt._(this._bytes, this._data, this._tables);

  final Uint8List _bytes;
  final ByteData _data;
  final Map<String, int> _tables;

  static _Sfnt? tryParse(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final data = ByteData.sublistView(bytes);
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

  /// The `hdmx` u8 advance row for [ppem], or null when absent.
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

  /// The unhinted `hmtx` advance of [glyph] in font units (monospace tail
  /// rows repeat the last stored width).
  int linearAdvance(int glyph) {
    final numH = _data.getUint16(_tables['hhea']! + 34);
    final at = _tables['hmtx']! + 4 * (glyph < numH ? glyph : numH - 1);
    return _data.getUint16(at);
  }

  /// Calls [visit] for every rune of the face's format-4 Windows cmap
  /// subtable (the BMP mapping GDI itself resolves through).
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
