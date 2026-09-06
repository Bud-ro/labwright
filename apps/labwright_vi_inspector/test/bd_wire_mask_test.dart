import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

const Set<int> kWireInkPalette = {
  0xff00ff,
  0x006666,
  0x0000ff,
  0x006600,
  0x666600,
  0xffff00,
  0xff6600,
  0x660066,
};

const int kMaskArtBox = 1;

const int kMaskTextRun = 2;

Uint8List sceneExclusionMask({
  required BdScene scene,
  required BdRaster raster,
  required int width,
  required int height,
}) {
  final mask = Uint8List(width * height);
  void fill(int left, int top, int right, int bottom, int bit) {
    final x0 = left < 0 ? 0 : left, y0 = top < 0 ? 0 : top;
    final x1 = right >= width ? width - 1 : right;
    final y1 = bottom >= height ? height - 1 : bottom;
    for (var y = y0; y <= y1; y++) {
      final row = y * width;
      for (var x = x0; x <= x1; x++) {
        mask[row + x] |= bit;
      }
    }
  }

  final cl = raster.content.left.toInt(), ct = raster.content.top.toInt();
  for (final o in scene.drawable) {
    final b = o.absBounds;
    if (b == null) continue;
    if (o.category == ViObjectKind.node ||
        o.category == ViObjectKind.terminal ||
        kBdTextLabelClasses.contains(o.objectClass)) {
      fill(
        b.left - 1 - cl,
        b.top - 1 - ct,
        b.right - cl,
        b.bottom - ct,
        kMaskArtBox,
      );
    }
  }
  for (final run in scene.paintedText) {
    final r = run.rect.inflate(1);
    fill(
      r.left.ceil(),
      r.top.ceil(),
      r.right.ceil() - 1,
      r.bottom.ceil() - 1,
      kMaskTextRun,
    );
  }
  return mask;
}

bool isTextFringe(int Function(int, int) refPixel, int rx, int ry) {
  bool dark(int rgb) =>
      rgb >= 0 &&
      ((rgb >> 16) & 0xff) < 0x80 &&
      ((rgb >> 8) & 0xff) < 0x80 &&
      (rgb & 0xff) < 0x80;
  return dark(refPixel(rx - 1, ry)) || dark(refPixel(rx + 1, ry));
}

({int missing, int excludedText}) missingWireInk({
  required Uint8List mask,
  required int Function(int, int) refPixel,
  required int Function(int, int) ourPixel,
  required int width,
  required int height,
  required int dx,
  required int dy,
}) {
  var missing = 0, excludedText = 0;
  for (var py = 0; py < height; py++) {
    for (var px = 0; px < width; px++) {
      final ref = refPixel(px + dx, py + dy);
      if (!kWireInkPalette.contains(ref)) continue;
      if (ourPixel(px, py) != 0xffffff) continue;
      final bits = mask[py * width + px];
      if (bits & kMaskArtBox != 0) continue;
      if (bits & kMaskTextRun != 0 &&
          isTextFringe(refPixel, px + dx, py + dy)) {
        excludedText++;
        continue;
      }
      missing++;
    }
  }
  return (missing: missing, excludedText: excludedText);
}

Future<
  ({
    int drawn,
    int perfect,
    int off,
    int missing,
    int excludedText,
    String detail,
  })?
>
perWireMaskGauge(WidgetTester tester, String pngName) async {
  final png = snippetPng(pngName);
  if (png == null) return null;
  final bytes = png.readAsBytesSync();
  final viBytes = extractSnippetVi(bytes)!;
  final bd = bestBlockDiagram(buildViModel(viBytes))!;
  final scene = BdScene(bd)..recordPaintedText = true;
  await loadRealTextFont();
  ({
    int drawn,
    int perfect,
    int off,
    int missing,
    int excludedText,
    String detail,
  })?
  gauge;
  await tester.runAsync(() async {
    final icons = await loadPrimIcons();
    final facades = await loadXnodeFacades(viBytes, bd);
    final raster = (await rasteriseBlockDiagram(
      bd,
      primIcons: icons,
      xnodeFacades: facades,
      scale: 1.0,
      margin: 2,
      scene: scene,
    ))!;
    final reference = await decodeReferenceImage(bytes);
    final result = await compareToReference(
      raster.image,
      reference.image,
      lockScale: 1.0 / raster.scale,
      anchorRects: bdStructureAnchorRects(bd, raster, drawable: scene.drawable),
    );
    final wirePhase = deriveWireCycleOffset(
      scene: scene,
      raster: raster,
      registration: result.registration,
      referenceRgba: result.referenceRgba,
      width: reference.image.width,
      height: reference.image.height,
    );
    final style = BdRenderStyle(wireCycleOffset: wirePhase);
    final rephased = (await rasteriseBlockDiagram(
      bd,
      primIcons: icons,
      xnodeFacades: facades,
      scale: 1.0,
      margin: 2,
      scene: scene,
      style: style,
    ))!;
    final reg = result.registration;
    final rw = reference.image.width;
    final rh = reference.image.height;
    final refB = result.referenceRgba;
    final basePx = (await rephased.image.toByteData())!.buffer.asUint8List();
    final iw = rephased.image.width, ih = rephased.image.height;

    int refPixel(int rx, int ry) {
      if (rx < 0 || ry < 0 || rx >= rw || ry >= rh) return -1;
      final i = (ry * rw + rx) * 4;
      return (refB[i] << 16) | (refB[i + 1] << 8) | refB[i + 2];
    }

    int ourPixel(Uint8List px, int x, int y) {
      final i = (y * iw + x) * 4;
      return (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    }

    final wires = scene.wires;
    var drawn = 0, perfect = 0, totalOff = 0;
    final imperfect = <String>[];
    for (final wire in wires) {
      final without = (await rasteriseBlockDiagram(
        bd,
        primIcons: icons,
        xnodeFacades: facades,
        scale: 1.0,
        margin: 2,
        wires: [
          for (final w in wires)
            if (w.signalOid != wire.signalOid) w,
        ],
        drawable: scene.drawable,
        style: style,
      ))!;
      final woPx = (await without.image.toByteData())!.buffer.asUint8List();
      var maskCount = 0, off = 0;
      for (var y = 0; y < ih; y++) {
        for (var x = 0; x < iw; x++) {
          final ours = ourPixel(basePx, x, y);
          if (ours == ourPixel(woPx, x, y)) continue;
          maskCount++;
          if (ours != refPixel(x + reg.dx.round(), y + reg.dy.round())) {
            off++;
          }
        }
      }
      without.image.dispose();
      if (maskCount == 0) continue;
      drawn++;
      if (off == 0) {
        perfect++;
      } else {
        totalOff += off;
        imperfect.add('sig=${wire.signalOid} off=$off');
      }
    }
    final ink = missingWireInk(
      mask: sceneExclusionMask(
        scene: scene,
        raster: rephased,
        width: iw,
        height: ih,
      ),
      refPixel: refPixel,
      ourPixel: (x, y) => ourPixel(basePx, x, y),
      width: iw,
      height: ih,
      dx: reg.dx.round(),
      dy: reg.dy.round(),
    );
    gauge = (
      drawn: drawn,
      perfect: perfect,
      off: totalOff,
      missing: ink.missing,
      excludedText: ink.excludedText,
      detail: 'wireCycleOffset=$wirePhase ${imperfect.join(" ")}',
    );
    raster.image.dispose();
    rephased.image.dispose();
    result.fitted.dispose();
    result.diffImage.dispose();
    reference.image.dispose();
    scene.dispose();
  });
  return gauge;
}

void main() {
  for (final (name, drawnFloor, offPin, missingPin) in const [
    ('Excel_Read_XLSX.png', 92, 0, 0),
    // MD5's 3 off px are wire ClearType fringe over prim1113's edge. TODO(wire-fringe).
    ('MD5.png', 187, 3, 0),
  ]) {
    testWidgets('$name per-wire masks: every drawn wire is byte-perfect', (
      tester,
    ) async {
      final gauge = await perWireMaskGauge(tester, name);
      if (gauge == null) {
        markTestSkipped('corpus not fetched');
        return;
      }
      // ignore: avoid_print
      print(
        '$name wire masks: drawn=${gauge.drawn} perfect=${gauge.perfect} '
        'offPx=${gauge.off} missing=${gauge.missing} '
        'excludedText=${gauge.excludedText} ${gauge.detail}',
      );
      expect(
        gauge.drawn,
        greaterThanOrEqualTo(drawnFloor),
        reason: 'drawn-wire floor',
      );
      expect(
        gauge.drawn - gauge.perfect,
        lessThanOrEqualTo(offPin == 0 ? 0 : 2),
        reason:
            'byte-perfect wire floor — a regression here un-fixes a wire '
            'that matched LabVIEW exactly',
      );
      expect(
        gauge.off,
        lessThanOrEqualTo(offPin),
        reason:
            'off-reference pixel ceiling over all wire masks — false wire '
            'ink the reference never shows; hold at zero (the sole nonzero '
            'pin is the documented uncomposited arrival fringe)',
      );
      expect(
        gauge.missing,
        lessThanOrEqualTo(missingPin),
        reason:
            'reference wire ink we leave white — every palette wire pixel '
            'outside node boxes is covered; re-pin DOWNWARD as routing '
            'lands, never up',
      );
    });
  }

  testWidgets('corpus wire-layer ratchet: off-reference and missing ink', (
    tester,
  ) async {
    final pngs = snippetCorpusPngs();
    if (pngs.isEmpty) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      final icons = await loadPrimIcons();
      var totalOff = 0, totalMissing = 0, totalExcludedText = 0;
      final rows = <String>[];
      for (final f in pngs) {
        final bytes = f.readAsBytesSync();
        final viBytes = extractSnippetVi(bytes)!;
        final model = buildViModel(viBytes);
        final bd = bestBlockDiagram(model);
        if (bd == null) continue;
        final scene = BdScene(bd)..recordPaintedText = true;
        if (scene.drawable.isEmpty) continue;
        final facades = await loadXnodeFacades(viBytes, bd);
        final raster0 = await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          xnodeFacades: facades,
          scale: 1.0,
          margin: 2,
          scene: scene,
        );
        if (raster0 == null) continue;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster0.image,
          reference.image,
          lockScale: 1.0 / raster0.scale,
          anchorRects: bdStructureAnchorRects(
            bd,
            raster0,
            drawable: scene.drawable,
          ),
        );
        final style = BdRenderStyle(
          wireCycleOffset: deriveWireCycleOffset(
            scene: scene,
            raster: raster0,
            registration: result.registration,
            referenceRgba: result.referenceRgba,
            width: reference.image.width,
            height: reference.image.height,
          ),
        );
        Future<BdRaster?> render(List<ViWire>? wires) => rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          xnodeFacades: facades,
          scale: 1.0,
          margin: 2,
          wires: wires ?? scene.wires,
          drawable: scene.drawable,
          style: style,
        );
        final withWires = (await render(null))!;
        final without = (await render(const []))!;
        final reg = result.registration;
        final rw = reference.image.width, rh = reference.image.height;
        final refB = result.referenceRgba;
        final ourB = (await withWires.image.toByteData())!.buffer.asUint8List();
        final woB = (await without.image.toByteData())!.buffer.asUint8List();
        final iw = withWires.image.width, ih = withWires.image.height;
        int refPixel(int rx, int ry) {
          if (rx < 0 || ry < 0 || rx >= rw || ry >= rh) return -1;
          final i = (ry * rw + rx) * 4;
          return (refB[i] << 16) | (refB[i + 1] << 8) | refB[i + 2];
        }

        int pixelOf(Uint8List px, int x, int y) {
          final i = (y * iw + x) * 4;
          return (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
        }

        final mask = sceneExclusionMask(
          scene: scene,
          raster: withWires,
          width: iw,
          height: ih,
        );
        var off = 0, excludedText = 0;
        for (var y = 0; y < ih; y++) {
          for (var x = 0; x < iw; x++) {
            final ours = pixelOf(ourB, x, y);
            if (ours == pixelOf(woB, x, y)) continue;
            if (ours == refPixel(x + reg.dx.round(), y + reg.dy.round())) {
              continue;
            }
            if (mask[y * iw + x] & kMaskTextRun != 0 &&
                !kWireInkPalette.contains(ours)) {
              excludedText++;
              continue;
            }
            off++;
          }
        }
        final ink = missingWireInk(
          mask: mask,
          refPixel: refPixel,
          ourPixel: (x, y) => pixelOf(ourB, x, y),
          width: iw,
          height: ih,
          dx: reg.dx.round(),
          dy: reg.dy.round(),
        );
        final missing = ink.missing;
        totalOff += off;
        totalMissing += missing;
        totalExcludedText += excludedText + ink.excludedText;
        final name = f.path.split('/').last;
        rows.add(
          '$name off=$off missing=$missing '
          'excludedText=${excludedText + ink.excludedText}',
        );
        raster0.image.dispose();
        withWires.image.dispose();
        without.image.dispose();
        result.fitted.dispose();
        result.diffImage.dispose();
        reference.image.dispose();
        scene.dispose();
      }
      rows.sort();
      // ignore: avoid_print
      rows.forEach(print);
      // ignore: avoid_print
      print(
        'corpus wire layer: off=$totalOff missing=$totalMissing '
        'excludedText=$totalExcludedText over ${rows.length} snippets',
      );
      expect(rows.length, greaterThanOrEqualTo(46), reason: 'corpus size');
      expect(
        totalOff,
        lessThanOrEqualTo(71239),
        reason:
            'wire-layer pixels off the reference, corpus-wide — re-pin '
            'DOWNWARD as decodes land, never up. (The into-icon arrival '
            'law — stop at the arrival line\'s opaque art edge, never '
            'overrun to the ink centre or against the closing direction — '
            'plus the junction first-beyond-row lattice took this 71,915 '
            '-> 71,825; the indexing-tunnel ring law took it -> 71,475; '
            'handing glyph-fringe pixels inside painted text runs to the '
            'text gauge -> 71,148; the whole-pixel text boxes then '
            'EXPOSED 3 net px the wider fractional boxes had masked — '
            'the crc trio each draw one 0x0000ff px beside the '
            '`bytes`/`8-bits` labels where the reference is white, a '
            'pre-existing wire overrun, offset by a 9 px ClassChildren '
            'improvement -> 71,151; the FTAB font-run decode (bold only '
            'where a weight-1000 entry says so) -> 71,150; the into-DCO '
            'leg trim — a leg attached inside a value display starts at '
            'the window furniture, not the stored attach under the '
            'transparent label gap -> 71,140; the label-anchor laws '
            '(0x800000 inset, boxW-1 centring, row-cell floor) -> 71,137. '
            'Then the in-text exclusion was narrowed to the BLEND pixels '
            'it can justify, which uncovered 102 px the whole-rect '
            'version had absorbed: 71,137 -> 71,239, no render change.) '
            'TODO(gauge-debt): those 102 px are real wire defects, not '
            'gauge noise — ClassChildren 60 (a magenta string wire drawn '
            'across the `\\.[Ll][Vv][Cc]…` constant\'s glyph row where '
            'the reference has none), Excel_Cell_to_Value 29, large 11 '
            '(the AA capture\'s 0x007f7f path wire vs our 0x006666), '
            'Pages 2. Fix them in the wire campaign and re-pin down.',
      );
      expect(
        totalMissing,
        lessThanOrEqualTo(21807),
        reason:
            'reference wire ink left white, corpus-wide — the undrawn/'
            'misrouted budget; re-pin DOWNWARD as routing lands, never up. '
            '(The icon-asset repairs — foreign fragments '
            'lopped, baked wires erased, full-box crops trimmed to their '
            'ink — took this 22,046 -> 22,035; the prim-origin/'
            'uncatalogued 3-point tiers, the container-face runs, and the '
            'Logical Shift terminal row -> 21,906; the array-shell wrap '
            'arrival face -> 21,872; the metric-matched text pass '
            'covering value-cell ink -> 21,807; bold style-run labels '
            '-> 21,802; the whole-pixel text boxes exposed 3 reference px '
            '(Pages, crc32_lookup_table) the wider fractional boxes had '
            'masked -> 21,805; the FTAB-sized 21 px heading '
            '(crc32_lookup_table, ink-bbox exact at 16 em) exposed 4 '
            'black glyph px of its own text the mis-sized small-bold box '
            'had masked — text-layer accuracy, not wire routing '
            '-> 21,809; the label-anchor laws\' corrected runs cover 2 '
            'more reference px -> 21,807. Narrowing the in-text exclusion '
            'to provable ClearType fringe moved this by 0: the whole-rect '
            'version was masking exactly 2 px corpus-wide, both fringe, '
            'both still excluded and both reported in excludedText — so '
            'every step above is a render change, none is masking.)',
      );
      expect(
        totalExcludedText,
        lessThanOrEqualTo(437),
        reason:
            'pixels handed to the text gauge — 435 glyph-AA blends on the '
            'off side, 2 reference ClearType fringes on the missing side. '
            'A rising bucket means the wire gauges are measuring less of '
            'the render, so it is pinned like the gauges themselves. '
            '(433 -> 435 when prim1537 gained a real asset: its art is '
            '29x13 inside a 32x32 node box, so the box margin the '
            'fabricated full-box plate used to ink is now honest canvas, '
            'and 2 Excel_Cell_to_RowCol string-wire pixels there stopped '
            'being accidentally covered. off and missing are unchanged. '
            'TODO(gauge-debt): those 2 px are a real wire-coverage gap '
            'the plate was hiding — fix them in the wire campaign and '
            're-pin down.)',
      );
    });
  });
}
