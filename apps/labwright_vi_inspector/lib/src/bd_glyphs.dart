/// Harvested text-run atlas for pixel-exact block-diagram label text.
///
/// LabVIEW's reference snippet PNGs draw label text with Windows subpixel
/// anti-aliasing quantised to the export palette. Corpus probing (46 snippet
/// references, ~3k glyph-sized ink components) shows the rasterisation is
/// **position-independent**: the same text at the same size is byte-identical
/// across positions and files. That makes the references themselves a
/// legitimate glyph source — this module segments known label strings out of
/// reference pixels and repaints them byte-exactly.
///
/// The harvest granularity is the **text run** (a label's space-separated
/// word): within a word the characters' anti-aliasing fringes touch, so a
/// word is one connected ink block with no background column to split at,
/// while the spaces between words always yield clean background columns.
/// Runs are stored with pairwise start-to-start offsets, so a multi-word
/// label repaints from its runs without any font-metric model.
///
/// Everything here operates on plain RGBA byte buffers (no dart:ui), so the
/// harvest/paint pipeline runs identically in tests and at integration time.
library;

import 'dart:typed_data';

/// A segmented ink cell cut from a reference image: the ink bounding box of
/// one text run (a word — anti-aliasing fringe included) on the label's
/// backing fill.
class BdGlyphSpan {
  const BdGlyphSpan({
    required this.x,
    required this.top,
    required this.bottom,
    required this.width,
    required this.rgb,
  });

  /// Leftmost ink column, in the source image's coordinates.
  final int x;

  /// Topmost ink row, in the source image's coordinates.
  final int top;

  /// Bottommost ink row (inclusive), in the source image's coordinates.
  final int bottom;

  /// Ink width in columns.
  final int width;

  /// `width * (bottom - top + 1) * 3` RGB bytes; background-coloured where
  /// the run has no ink.
  final Uint8List rgb;

  int get height => bottom - top + 1;
}

/// One harvested text run: a word's ink bitmap.
class BdGlyph {
  const BdGlyph({
    required this.run,
    required this.width,
    required this.height,
    required this.rgb,
  });

  /// The text this bitmap draws (one space-free run).
  final String run;

  /// Ink width in columns (anti-aliasing fringe included).
  final int width;

  /// Ink height in rows.
  final int height;

  /// `width * height * 3` RGB bytes; background-coloured where the run has
  /// no ink.
  final Uint8List rgb;
}

/// Whether the RGBA pixel at ([x], [y]) of an [imageWidth]-wide buffer
/// differs from the 0xRRGGBB [background] — i.e. is ink.
bool _ink(Uint8List rgba, int imageWidth, int x, int y, int background) {
  final o = (y * imageWidth + x) * 4;
  return rgba[o] != (background >> 16) ||
      rgba[o + 1] != ((background >> 8) & 0xff) ||
      rgba[o + 2] != (background & 0xff);
}

/// Segments the region `[left..right) x [top..bottom)` of an RGBA image into
/// run cells: the region is trimmed to its ink rows (empty list if the ink
/// rows are not one contiguous band — a wrapped multi-line label), then split
/// at background-only columns; each run of inked columns becomes one
/// [BdGlyphSpan] trimmed to its own ink rows. Ink is any pixel differing
/// from the 0xRRGGBB [background] (the text's backing fill — white for plain
/// labels).
List<BdGlyphSpan> segmentGlyphSpans(
  Uint8List rgba,
  int imageWidth, {
  required int left,
  required int top,
  required int right,
  required int bottom,
  int background = 0xffffff,
}) {
  // Trim to the inked row band; reject split bands (multi-line text).
  var bandTop = -1, bandBottom = -1;
  var inGap = false;
  for (var y = top; y < bottom; y++) {
    var has = false;
    for (var x = left; x < right; x++) {
      if (_ink(rgba, imageWidth, x, y, background)) {
        has = true;
        break;
      }
    }
    if (has) {
      if (bandTop < 0) bandTop = y;
      if (inGap) return const []; // a second band
      bandBottom = y;
    } else if (bandTop >= 0) {
      inGap = true;
    }
  }
  if (bandTop < 0) return const [];
  // Split at background-only columns.
  final spans = <BdGlyphSpan>[];
  var runStart = -1;
  for (var x = left; x <= right; x++) {
    var has = false;
    if (x < right) {
      for (var y = bandTop; y <= bandBottom; y++) {
        if (_ink(rgba, imageWidth, x, y, background)) {
          has = true;
          break;
        }
      }
    }
    if (has) {
      runStart = runStart < 0 ? x : runStart;
      continue;
    }
    if (runStart < 0) continue;
    // Close the cell [runStart..x): trim rows, copy pixels.
    var cellTop = bandBottom, cellBottom = bandTop;
    for (var y = bandTop; y <= bandBottom; y++) {
      for (var cx = runStart; cx < x; cx++) {
        if (_ink(rgba, imageWidth, cx, y, background)) {
          if (y < cellTop) cellTop = y;
          if (y > cellBottom) cellBottom = y;
        }
      }
    }
    final w = x - runStart, h = cellBottom - cellTop + 1;
    final rgb = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      for (var cx = 0; cx < w; cx++) {
        final src = ((cellTop + y) * imageWidth + runStart + cx) * 4;
        final dst = (y * w + cx) * 3;
        rgb[dst] = rgba[src];
        rgb[dst + 1] = rgba[src + 1];
        rgb[dst + 2] = rgba[src + 2];
      }
    }
    spans.add(
      BdGlyphSpan(
        x: runStart,
        top: cellTop,
        bottom: cellBottom,
        width: w,
        rgb: rgb,
      ),
    );
    runStart = -1;
  }
  return spans;
}

/// The space-free runs of [text] with their character index ranges.
List<({int start, int end, String run})> _runsOf(String text) {
  final runs = <({int start, int end, String run})>[];
  var start = -1;
  for (var i = 0; i <= text.length; i++) {
    final space = i == text.length || text[i] == ' ';
    if (!space) {
      start = start < 0 ? i : start;
    } else if (start >= 0) {
      runs.add((start: start, end: i, run: text.substring(start, i)));
      start = -1;
    }
  }
  return runs;
}

/// Accumulates runs and pairwise offsets from segmented label rows,
/// byte-verifying every repeated run against its first harvest. One harvest
/// covers one [background] fill — anti-aliasing is blended against the
/// backing colour, so bitmaps only transfer between labels sharing it.
class BdGlyphHarvest {
  BdGlyphHarvest({this.background = 0xffffff, this.onConflict});

  /// Called when a repeated run/adjacency harvest disagrees with the stored
  /// one (diagnostics; the key is dropped either way).
  final void Function(String key, String detail)? onConflict;

  /// The 0xRRGGBB backing fill the harvested bitmaps are blended against.
  final int background;

  final Map<String, BdGlyph> _glyphs = {};

  /// Offset key (the label substring from one run's start to the next run's
  /// end, spaces included) to the start-to-start offset between the two runs'
  /// ink boxes.
  final Map<String, ({int dx, int dy})> _offsets = {};

  /// Runs whose repeated harvests disagreed (dropped from the atlas) and
  /// offset keys with conflicting offsets.
  final Set<String> conflicts = {};

  /// Run occurrences byte-verified against an already-harvested bitmap.
  int verifiedRepeats = 0;

  /// Harvests one label row: [text]'s space-separated runs mapped one-to-one
  /// onto [spans] (in x order). Returns false — harvesting nothing — when the
  /// counts disagree (foreign ink in the crop, or a mis-recovered caption).
  bool addLabel(String text, List<BdGlyphSpan> spans) {
    final runs = _runsOf(text);
    if (runs.length != spans.length || spans.isEmpty) return false;
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      final glyph = BdGlyph(
        run: runs[i].run,
        width: s.width,
        height: s.height,
        rgb: s.rgb,
      );
      final prior = _glyphs[glyph.run];
      if (prior == null) {
        if (!conflicts.contains(glyph.run)) _glyphs[glyph.run] = glyph;
      } else if (_sameGlyph(prior, glyph)) {
        verifiedRepeats++;
      } else {
        conflicts.add(glyph.run);
        _glyphs.remove(glyph.run);
        onConflict?.call(
          glyph.run,
          '${prior.width}x${prior.height} vs ${glyph.width}x${glyph.height}',
        );
      }
      if (i + 1 < spans.length) {
        final key = text.substring(runs[i].start, runs[i + 1].end);
        final offset = (dx: spans[i + 1].x - s.x, dy: spans[i + 1].top - s.top);
        final prior = _offsets[key];
        if (prior == null) {
          if (!conflicts.contains(key)) _offsets[key] = offset;
        } else if (prior != offset) {
          conflicts.add(key);
          _offsets.remove(key);
          onConflict?.call(key, 'offset $prior vs $offset');
        }
      }
    }
    return true;
  }

  static bool _sameGlyph(BdGlyph a, BdGlyph b) {
    if (a.width != b.width || a.height != b.height) return false;
    for (var i = 0; i < a.rgb.length; i++) {
      if (a.rgb[i] != b.rgb[i]) return false;
    }
    return true;
  }

  BdGlyphAtlas build() => BdGlyphAtlas(
    Map.unmodifiable(_glyphs),
    Map.unmodifiable(_offsets),
    background: background,
  );
}

/// An immutable harvested atlas: per-run bitmaps plus observed pairwise
/// offsets, with a byte-exact [paint] for labels whose runs and adjacencies
/// were all harvested.
class BdGlyphAtlas {
  const BdGlyphAtlas(this.glyphs, this.offsets, {this.background = 0xffffff});

  /// The 0xRRGGBB backing fill every bitmap is blended against; [paint]
  /// fills its canvas with it.
  final int background;

  /// Space-free run text to its harvested bitmap.
  final Map<String, BdGlyph> glyphs;

  /// Adjacent-run key (the label substring spanning both runs) to the
  /// start-to-start offset between their ink boxes.
  final Map<String, ({int dx, int dy})> offsets;

  /// The run placements for [text] relative to its first run's ink origin,
  /// or null when a run or adjacency offset is missing.
  List<({BdGlyph glyph, int x, int y})>? _layout(String text) {
    final runs = _runsOf(text);
    if (runs.isEmpty) return null;
    final placed = <({BdGlyph glyph, int x, int y})>[];
    var x = 0, y = 0;
    for (var i = 0; i < runs.length; i++) {
      final glyph = glyphs[runs[i].run];
      if (glyph == null) return null;
      placed.add((glyph: glyph, x: x, y: y));
      if (i + 1 < runs.length) {
        final offset = offsets[text.substring(runs[i].start, runs[i + 1].end)];
        if (offset == null) return null;
        x += offset.dx;
        y += offset.dy;
      }
    }
    return placed;
  }

  /// The exact ink width of [text], or null when not fully harvested.
  int? measureWidth(String text) {
    final layout = _layout(text);
    if (layout == null) return null;
    var right = 0;
    for (final p in layout) {
      if (p.x + p.glyph.width > right) right = p.x + p.glyph.width;
    }
    return right;
  }

  /// Paints [text] onto a background-filled RGB canvas exactly as the
  /// reference draws it, or null when a run or adjacency was not harvested.
  /// The canvas is the ink bounding box of the placed runs.
  ({int width, int height, Uint8List rgb})? paint(String text) {
    final layout = _layout(text);
    if (layout == null) return null;
    var minY = 0, width = 0, maxY = 0;
    for (final p in layout) {
      if (p.y < minY) minY = p.y;
      if (p.y + p.glyph.height > maxY) maxY = p.y + p.glyph.height;
      if (p.x + p.glyph.width > width) width = p.x + p.glyph.width;
    }
    final height = maxY - minY;
    final rgb = Uint8List(width * height * 3);
    for (var i = 0; i < width * height; i++) {
      rgb[i * 3] = background >> 16;
      rgb[i * 3 + 1] = (background >> 8) & 0xff;
      rgb[i * 3 + 2] = background & 0xff;
    }
    for (final p in layout) {
      final g = p.glyph;
      for (var y = 0; y < g.height; y++) {
        final src = y * g.width * 3;
        final dst = ((p.y - minY + y) * width + p.x) * 3;
        rgb.setRange(dst, dst + g.width * 3, g.rgb, src);
      }
    }
    return (width: width, height: height, rgb: rgb);
  }

  /// Serialises the atlas: `'BDGA'`, `u16 version=1`, `u24 background`,
  /// `u16 runCount`, per run `[u8 textLen][text][u16 width][u16 height]
  /// [rgb]`, `u16 offsetCount`, per entry `[u8 keyLen][key][s16 dx][s8 dy]`.
  /// Big-endian.
  Uint8List toBytes() {
    final out = BytesBuilder(copy: false);
    void u16(int v) => out.add([(v >> 8) & 0xff, v & 0xff]);
    out.add('BDGA'.codeUnits);
    u16(1);
    out.add([background >> 16, (background >> 8) & 0xff, background & 0xff]);
    final runs = glyphs.keys.toList()..sort();
    u16(runs.length);
    for (final run in runs) {
      final g = glyphs[run]!;
      out.add([run.length, ...run.codeUnits]);
      u16(g.width);
      u16(g.height);
      out.add(g.rgb);
    }
    final keys = offsets.keys.toList()..sort();
    u16(keys.length);
    for (final key in keys) {
      final o = offsets[key]!;
      out.add([key.length, ...key.codeUnits]);
      u16(o.dx & 0xffff);
      out.add([o.dy & 0xff]);
    }
    return out.toBytes();
  }

  /// Decodes [toBytes] output; null on any framing mismatch.
  static BdGlyphAtlas? fromBytes(Uint8List bytes) {
    if (bytes.length < 11 ||
        String.fromCharCodes(bytes, 0, 4) != 'BDGA' ||
        ByteData.sublistView(bytes).getUint16(4) != 1) {
      return null;
    }
    final bd = ByteData.sublistView(bytes);
    final background = (bytes[6] << 16) | (bytes[7] << 8) | bytes[8];
    var pos = 9;
    if (pos + 2 > bytes.length) return null;
    final runCount = bd.getUint16(pos);
    pos += 2;
    final glyphs = <String, BdGlyph>{};
    for (var i = 0; i < runCount; i++) {
      if (pos >= bytes.length) return null;
      final textLen = bytes[pos];
      if (pos + 1 + textLen + 4 > bytes.length) return null;
      final run = String.fromCharCodes(bytes, pos + 1, pos + 1 + textLen);
      pos += 1 + textLen;
      final width = bd.getUint16(pos), height = bd.getUint16(pos + 2);
      pos += 4;
      final byteCount = width * height * 3;
      if (pos + byteCount > bytes.length) return null;
      glyphs[run] = BdGlyph(
        run: run,
        width: width,
        height: height,
        rgb: Uint8List.sublistView(bytes, pos, pos + byteCount),
      );
      pos += byteCount;
    }
    if (pos + 2 > bytes.length) return null;
    final offsetCount = bd.getUint16(pos);
    pos += 2;
    final offsets = <String, ({int dx, int dy})>{};
    for (var i = 0; i < offsetCount; i++) {
      if (pos >= bytes.length) return null;
      final len = bytes[pos];
      if (pos + 1 + len + 3 > bytes.length) return null;
      final key = String.fromCharCodes(bytes, pos + 1, pos + 1 + len);
      offsets[key] = (
        dx: bd.getUint16(pos + 1 + len).toSigned(16),
        dy: bytes[pos + 3 + len].toSigned(8),
      );
      pos += len + 4;
    }
    return BdGlyphAtlas(
      Map.unmodifiable(glyphs),
      Map.unmodifiable(offsets),
      background: background,
    );
  }
}
