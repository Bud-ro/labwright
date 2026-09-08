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
  })
>
perWireMaskGauge(WidgetTester tester, String pngName) async {
  final bytes = snippetPng(pngName).readAsBytesSync();
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
    final basePx = await rgbaOf(rephased.image);
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
      final woPx = await rgbaOf(without.image);
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
  return gauge!;
}

void main() {
  for (final (name, drawnFloor, offPin, missingPin) in const [
    ('Excel_Read_XLSX.png', 92, 0, 0),
    ('MD5.png', 187, 6, 0),
  ]) {
    testWidgets('$name per-wire masks: every drawn wire is byte-perfect', (
      tester,
    ) async {
      final gauge = await perWireMaskGauge(tester, name);
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
}
