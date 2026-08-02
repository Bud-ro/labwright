import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_glyphs.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Harvests a text-run atlas from the snippet references' own label text and
/// proves it repaints byte-exactly: every registered snippet's visible
/// single-line labels are segmented into word cells (per backing fill —
/// plain white or a free label's tinted box), accumulated into per-background
/// [BdGlyphAtlas]es (repeat runs byte-verified — the reference rasteriser is
/// position-independent), and then every harvested label is REPAINTED from
/// the atlases and byte-compared against the reference pixels it came from.
/// Runs transfer across files: a label painted with runs first harvested
/// elsewhere must still match exactly.
///
/// `--dart-define=EXTRACT_BD_GLYPHS=1` additionally writes the
/// white-background atlas to `assets/bd_glyphs.atlas` for the diagram
/// painter to consume.
void main() {
  const extract = String.fromEnvironment('EXTRACT_BD_GLYPHS');
  testWidgets('harvested glyph atlas repaints reference label text byte-exactly', (
    tester,
  ) async {
    await loadRealTextFont();
    final pngs = snippetCorpusPngs();
    if (pngs.isEmpty) return;
    final harvests = <int, BdGlyphHarvest>{};
    // Every successfully harvested label row, kept for the paint-back proof.
    final rows =
        <
          ({
            String text,
            String file,
            int background,
            int left,
            int top,
            int bottom,
            Uint8List rgba,
            int imageWidth,
          })
        >[];
    final firstSeen = <String, String>{}; // run -> file first harvested
    await tester.runAsync(() async {
      for (final f in pngs) {
        final bytes = f.readAsBytesSync();
        final vi = extractSnippetVi(bytes);
        if (vi == null) continue;
        final model = buildViModel(vi);
        final bd = bestBlockDiagram(model);
        if (bd == null) continue;
        final raster = await rasteriseBlockDiagram(bd, scale: 1.0, margin: 2);
        if (raster == null) continue;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(bd, raster),
        );
        if (!result.registered) continue;
        final reg = result.registration;
        final placement = comparePlacement(
          diagram: bd,
          raster: raster,
          registration: reg,
          referenceRgba: result.referenceRgba,
          width: reference.image.width,
          height: reference.image.height,
        );
        if (placement.objects == 0 || placement.excessSupport < 0.7) continue;
        final refW = reference.image.width, refH = reference.image.height;
        final rgba = result.referenceRgba;
        final name = f.uri.pathSegments.last;
        for (final o in bd.objects) {
          // Plain label parts only (0x0a); the case selector's centred value
          // text (0x95) is out of the prototype's scope.
          if (o.kind != 0x0a) continue;
          if (o.isLabelHidden) continue;
          // The label's display text, resolved the way the renderer resolves
          // it: the recovered caption, else the nearest ancestor's decoded
          // constant value, else the owner's data-space name.
          var text = o.label?.trim();
          if (text == null || text.isEmpty) {
            String? constValue;
            var ancestorOid = o.parentOid;
            for (var hop = 0; hop < 4 && ancestorOid != null; hop++) {
              final ancestor = bd.byId[ancestorOid];
              if (ancestor == null) break;
              final decoded = ancestor.constText?.trim();
              if (decoded != null && decoded.isNotEmpty) {
                constValue = decoded;
                break;
              }
              ancestorOid = ancestor.parentOid;
            }
            text = constValue ?? bd.byId[o.parentOid]?.typeName;
          }
          if (text == null || text.length < 2) continue;
          if (text.codeUnits.any((c) => c < 0x20 || c > 0x7e)) continue;
          final b = o.absBounds;
          if (b == null || b.width <= 0 || b.height <= 0) continue;
          const pad = 2;
          final left =
              ((b.left - raster.content.left) * raster.scale * reg.scale +
                      reg.dx)
                  .round() -
              pad;
          final top =
              ((b.top - raster.content.top) * raster.scale * reg.scale + reg.dy)
                  .round() -
              pad;
          final w = (b.width * raster.scale * reg.scale).round() + 2 * pad;
          final h = (b.height * raster.scale * reg.scale).round() + 2 * pad;
          if (left < 0 || top < 0 || left + w > refW || top + h > refH) {
            continue;
          }
          // White surround: nothing else may touch the crop — foreign ink on
          // the ring means wires/nodes overlap the label bounds.
          var whiteRing = true;
          for (var x = left; x < left + w && whiteRing; x++) {
            whiteRing =
                !_inky(rgba, refW, x, top) &&
                !_inky(rgba, refW, x, top + h - 1);
          }
          for (var y = top; y < top + h && whiteRing; y++) {
            whiteRing =
                !_inky(rgba, refW, left, y) &&
                !_inky(rgba, refW, left + w - 1, y);
          }
          if (!whiteRing) continue;
          // A free label draws a bordered backing box; segment its interior
          // against the modal fill colour. An unboxed label segments the
          // whole crop against white.
          final region = _stripBackingBox(rgba, refW, left, top, w, h);
          final spans = segmentGlyphSpans(
            rgba,
            refW,
            left: region.left,
            top: region.top,
            right: region.right,
            bottom: region.bottom,
            background: region.background,
          );
          if (spans.isEmpty) continue;
          final fresh = <String>{
            for (final run in text.split(' '))
              if (run.isNotEmpty && !firstSeen.containsKey(run)) run,
          };
          final harvest = harvests.putIfAbsent(
            region.background,
            () => BdGlyphHarvest(background: region.background),
          );
          if (!harvest.addLabel(text, spans)) continue;
          for (final run in fresh) {
            firstSeen[run] = name;
          }
          rows.add((
            text: text,
            file: name,
            background: region.background,
            left: spans.first.x,
            top: spans.map((s) => s.top).reduce((a, b) => a < b ? a : b),
            bottom: spans.map((s) => s.bottom).reduce((a, b) => a > b ? a : b),
            rgba: rgba,
            imageWidth: refW,
          ));
        }
      }
    });
    // Conflicting keys (labels styled with another font/size reuse a word)
    // drop out of the atlas; the paint-back proof below stays strict for
    // everything that remains.
    final conflictCount = harvests.values.fold(
      0,
      (a, x) => a + x.conflicts.length,
    );
    final atlases = {for (final e in harvests.entries) e.key: e.value.build()};
    // Serialization roundtrip is exact.
    for (final atlas in atlases.values) {
      final rebuilt = BdGlyphAtlas.fromBytes(atlas.toBytes())!;
      expect(rebuilt.background, atlas.background);
      expect(rebuilt.glyphs.length, atlas.glyphs.length);
      expect(rebuilt.offsets, atlas.offsets);
    }
    // Paint-back proof: every harvested label repaints byte-identically at
    // its reference location, including labels whose runs came from OTHER
    // files.
    var painted = 0, exact = 0, crossFile = 0, crossFileExact = 0;
    for (final row in rows) {
      final out = atlases[row.background]!.paint(row.text);
      if (out == null) continue;
      painted++;
      final isCross = row.text
          .split(' ')
          .any((run) => run.isNotEmpty && firstSeen[run] != row.file);
      if (isCross) crossFile++;
      var same = out.height == row.bottom - row.top + 1;
      for (var y = 0; same && y < out.height; y++) {
        for (var x = 0; same && x < out.width; x++) {
          final src = ((row.top + y) * row.imageWidth + row.left + x) * 4;
          final dst = (y * out.width + x) * 3;
          same =
              row.rgba[src] == out.rgb[dst] &&
              row.rgba[src + 1] == out.rgb[dst + 1] &&
              row.rgba[src + 2] == out.rgb[dst + 2];
        }
      }
      if (same) {
        exact++;
        if (isCross) crossFileExact++;
      }
    }
    final totalGlyphs = atlases.values.fold(0, (a, x) => a + x.glyphs.length);
    final totalOffsets = atlases.values.fold(0, (a, x) => a + x.offsets.length);
    final repeats = harvests.values.fold(0, (a, x) => a + x.verifiedRepeats);
    // ignore: avoid_print
    print(
      'bd_glyphs: labels=${rows.length} backgrounds=${atlases.keys.map((c) => c.toRadixString(16)).toList()} '
      'runs=$totalGlyphs offsets=$totalOffsets verifiedRepeats=$repeats '
      'conflicts=$conflictCount '
      'painted=$painted exact=$exact crossFile=$crossFile crossFileExact=$crossFileExact',
    );
    expect(painted, greaterThanOrEqualTo(25));
    expect(exact, painted, reason: 'every repainted label must be byte-exact');
    expect(
      crossFileExact,
      greaterThan(0),
      reason: 'glyphs must transfer byte-exactly across files',
    );
    if (extract == '1') {
      final appDir = repoDir('apps/labwright_vi_inspector')!.path;
      // The white-background atlas is the diagram painter's; tinted-backing
      // harvests stay proof-only until the painter draws label backings.
      final atlas = atlases[0xffffff];
      if (atlas != null) {
        File(
          '$appDir/assets/bd_glyphs.atlas',
        ).writeAsBytesSync(atlas.toBytes());
      }
    }
  });
}

bool _inky(Uint8List rgba, int width, int x, int y) {
  final o = (y * width + x) * 4;
  return (rgba[o] & rgba[o + 1] & rgba[o + 2]) != 0xff;
}

/// When the crop holds a rectangular backing box (a free label's border: the
/// crop's ink bounding box has fully-inked edge rows and columns), returns
/// the box interior and its modal fill colour; otherwise the whole crop
/// against white.
({int left, int top, int right, int bottom, int background}) _stripBackingBox(
  Uint8List rgba,
  int imageWidth,
  int left,
  int top,
  int w,
  int h,
) {
  final whole = (
    left: left,
    top: top,
    right: left + w,
    bottom: top + h,
    background: 0xffffff,
  );
  // Ink bounding box of the crop.
  var minX = left + w, maxX = left - 1, minY = top + h, maxY = top - 1;
  for (var y = top; y < top + h; y++) {
    for (var x = left; x < left + w; x++) {
      if (!_inky(rgba, imageWidth, x, y)) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX - minX < 4 || maxY - minY < 4) return whole;
  // A backing box means the bbox edges are solid border runs.
  for (var x = minX; x <= maxX; x++) {
    if (!_inky(rgba, imageWidth, x, minY) ||
        !_inky(rgba, imageWidth, x, maxY)) {
      return whole;
    }
  }
  for (var y = minY; y <= maxY; y++) {
    if (!_inky(rgba, imageWidth, minX, y) ||
        !_inky(rgba, imageWidth, maxX, y)) {
      return whole;
    }
  }
  // Modal interior colour = the backing fill.
  final counts = <int, int>{};
  for (var y = minY + 1; y < maxY; y++) {
    for (var x = minX + 1; x < maxX; x++) {
      final o = (y * imageWidth + x) * 4;
      final c = (rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2];
      counts[c] = (counts[c] ?? 0) + 1;
    }
  }
  var fill = 0xffffff, best = 0;
  counts.forEach((c, n) {
    if (n > best) {
      fill = c;
      best = n;
    }
  });
  return (
    left: minX + 1,
    top: minY + 1,
    right: maxX,
    bottom: maxY,
    background: fill,
  );
}
