import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Wire pixel-perfection ratchets — the tests that grow the "known perfect"
/// region of the render wire by wire, measured BOTH ways:
///
///  * OUR ink must be right: leave-one-out per-wire masks (re-rasterise
///    without a wire; the changed pixels are its visible ink and every one
///    must byte-equal the reference).
///  * The REFERENCE's ink must be covered: reference pixels of the wire-ink
///    palette that we leave white — outside node/terminal/label boxes (the
///    icon campaign's art) and outside painted text runs (the text
///    campaign's) — are MISSING wire ink (undrawn or misrouted wires),
///    gauged without reference to what we chose to draw.
///
/// The floors are exact-state pins, not aspirations: a change that makes a
/// perfect wire imperfect, or uncovers reference ink, fails here. When a fix
/// (or new routing) moves a count, re-pin to the measured value and PROVE
/// the delta against reference ink — never loosen. The same technique is
/// the template for pinning every other drawn element class later.
///
/// Known Excel imperfect remainder (100 px over 15 wires at pin time): the
/// braid T-junction art (sig 534), a prim stub whose output type is
/// uncatalogued (2398), wire ink under the film-strip band (2806/495),
/// crossing gaps against still-unrouted wires (5458/6282), patterned-band
/// junction shapes (4838), bend-corner pattern trims, and anti-aliased
/// chrome (terminal arrows) blending over wire ink. The missing-ink budget
/// is dominated by the visible-frame signals whose routes are not yet
/// decoded (Excel's 22 undrawn wires; see the census below).

/// The wire-stroke ink palette on the white canvas (web-safe captures; an
/// AA capture's blended wires undercount, which only slackens the gauge).
const Set<int> kWireInkPalette = {
  0xff00ff, // string family
  0x006666, // path
  0x0000ff, // integer
  0x006600, // boolean
  0x666600, // error braid flanks
  0xffff00, // error braid weave
  0xff6600, // float
  0x660066, // tag
};

/// Reference wire-ink pixels that [ourPixel] leaves white, outside every
/// node/terminal/label box of [scene] and outside the painter's own text
/// runs ([BdScene.paintedText], grown 1 px) — the coverage gauge. Text
/// rects are excluded because the reference's subpixel-AA glyph fringes
/// rasterise to exact wire-palette colours (MD5's array-index digits ring
/// their black cores with 0x660066/0x006666 columns): that ink belongs to
/// the text layer, not to wire coverage.
int missingWireInk({
  required BdScene scene,
  required BdRaster raster,
  required int Function(int, int) refPixel,
  required int Function(int, int) ourPixel,
  required int width,
  required int height,
  required int dx,
  required int dy,
}) {
  final boxes = <HeapRect>[];
  for (final o in scene.drawable) {
    final b = o.absBounds;
    if (b == null) continue;
    if (o.category == ViObjectKind.node ||
        o.category == ViObjectKind.terminal ||
        kBdTextLabelCodes.contains(o.kind)) {
      boxes.add(b);
    }
  }
  final textRects = [for (final run in scene.paintedText) run.rect.inflate(1)];
  var missing = 0;
  for (var py = 0; py < height; py++) {
    for (var px = 0; px < width; px++) {
      final ref = refPixel(px + dx, py + dy);
      if (!kWireInkPalette.contains(ref)) continue;
      if (ourPixel(px, py) != 0xffffff) continue;
      final x = px + raster.content.left.toInt();
      final y = py + raster.content.top.toInt();
      var inBox = false;
      for (final b in boxes) {
        if (x >= b.left - 1 &&
            x <= b.right &&
            y >= b.top - 1 &&
            y <= b.bottom) {
          inBox = true;
          break;
        }
      }
      if (!inBox) {
        for (final r in textRects) {
          if (r.contains(Offset(px.toDouble(), py.toDouble()))) {
            inBox = true;
            break;
          }
        }
      }
      if (!inBox) missing++;
    }
  }
  return missing;
}

/// The per-wire leave-one-out gauge over one snippet reference: renders the
/// diagram, then re-renders without each wire in turn — the changed pixels
/// are that wire's visible ink and every one is compared byte-for-byte to
/// the registered reference — and finally measures the reference wire ink
/// left uncovered ([missingWireInk]). Null when the corpus is not fetched.
Future<({int drawn, int perfect, int off, int missing, String detail})?>
perWireMaskGauge(WidgetTester tester, String pngName) async {
  final dir = repoDir(
    'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
  );
  if (dir == null) return null;
  final f = dir
      .listSync(recursive: true)
      .whereType<File>()
      .firstWhere((x) => x.path.endsWith('/$pngName'));
  final bytes = f.readAsBytesSync();
  final viBytes = extractSnippetVi(bytes)!;
  final bd = bestBlockDiagram(buildViModel(viBytes))!;
  final scene = BdScene(bd);
  await loadRealTextFont();
  ({int drawn, int perfect, int off, int missing, String detail})? gauge;
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
    // The capture's wire-cycle phase (screen-anchored patterns; see
    // [BdRenderStyle.wireCycleOffset]) — derived exactly as the oracle
    // does, then both renders below use it.
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
    final missing = missingWireInk(
      scene: scene,
      raster: rephased,
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
      missing: missing,
      detail: 'wireCycleOffset=$wirePhase ${imperfect.join(" ")}',
    );
    raster.image.dispose();
    rephased.image.dispose();
    result.fitted.dispose();
    result.diffImage.dispose();
    reference.image.dispose();
  });
  return gauge;
}

void main() {
  // Per-snippet exact-state pins: every drawn wire byte-perfect, zero
  // off-reference wire-layer pixels, and the missing-ink pin. A change
  // that moves a count must re-prove it against reference ink and re-pin
  // DOWNWARD (missing) / hold at zero (off), never loosen.
  for (final (name, drawnFloor, offPin, missingPin) in const [
    ('Excel_Read_XLSX.png', 92, 0, 0),
    // MD5's 3 off px are the wires' own ClearType fringe over prim1113's
    // triangle edge — the blend pixels were removed from the icon asset on
    // review (they are wire ink, not icon ink) and the wire pass does not
    // yet composite arrival fringes. TODO(wire-fringe).
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
        'offPx=${gauge.off} missing=${gauge.missing} ${gauge.detail}',
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
      var totalOff = 0, totalMissing = 0;
      final rows = <String>[];
      for (final f in pngs) {
        final bytes = f.readAsBytesSync();
        final viBytes = extractSnippetVi(bytes)!;
        final model = buildViModel(viBytes);
        final bd = bestBlockDiagram(model);
        if (bd == null) continue;
        final scene = BdScene(bd);
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

        // The wire LAYER's own visible pixels (with-wires vs without) that
        // miss the reference. Pixels inside the painter's own text runs
        // (grown 1 px) are the text layer's: a glyph's AA blend shifts
        // with the wire underneath it, so the with/without diff picks the
        // glyph fringe up as "wire" ink there; its accuracy is the text
        // campaign's gauge, not this ratchet's.
        final textRects = [
          for (final run in scene.paintedText) run.rect.inflate(1),
        ];
        bool inText(int x, int y) {
          for (final r in textRects) {
            if (r.contains(Offset(x.toDouble(), y.toDouble()))) return true;
          }
          return false;
        }

        var off = 0;
        for (var y = 0; y < ih; y++) {
          for (var x = 0; x < iw; x++) {
            final ours = pixelOf(ourB, x, y);
            if (ours == pixelOf(woB, x, y)) continue;
            if (ours != refPixel(x + reg.dx.round(), y + reg.dy.round()) &&
                !inText(x, y)) {
              off++;
            }
          }
        }
        final missing = missingWireInk(
          scene: scene,
          raster: withWires,
          refPixel: refPixel,
          ourPixel: (x, y) => pixelOf(ourB, x, y),
          width: iw,
          height: ih,
          dx: reg.dx.round(),
          dy: reg.dy.round(),
        );
        totalOff += off;
        totalMissing += missing;
        final name = f.path.split('/').last;
        rows.add('$name off=$off missing=$missing');
        raster0.image.dispose();
        withWires.image.dispose();
        without.image.dispose();
        result.fitted.dispose();
        result.diffImage.dispose();
        reference.image.dispose();
      }
      rows.sort();
      // ignore: avoid_print
      rows.forEach(print);
      // ignore: avoid_print
      print(
        'corpus wire layer: off=$totalOff missing=$totalMissing '
        'over ${rows.length} snippets',
      );
      expect(rows.length, greaterThanOrEqualTo(46), reason: 'corpus size');
      // Aggregate exact-state pins over the 46 snippets (the two AA-machine
      // captures, fg/large, contribute constant reference variance that can
      // never byte-converge; they still guard against regressions).
      expect(
        totalOff,
        lessThanOrEqualTo(71137),
        reason:
            'wire-layer pixels off the reference, corpus-wide — re-pin '
            'DOWNWARD as decodes land. (The into-icon arrival law — stop '
            'at the arrival line\'s opaque art edge, never overrun to the '
            'ink centre or against the closing direction — plus the '
            'junction first-beyond-row lattice took this 71,915 -> '
            '71,825; the indexing-tunnel ring law took it -> 71,475; '
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
            '(0x800000 inset, boxW-1 centring, row-cell floor) -> '
            '71,137.)',
      );
      expect(
        totalMissing,
        lessThanOrEqualTo(21807),
        reason:
            'reference wire ink left white, corpus-wide — the undrawn/'
            'misrouted budget; re-pin DOWNWARD as routing lands, never up '
            '(text-layer exposures documented per pixel are the sole '
            'exception). (The icon-asset repairs — foreign fragments '
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
            'more reference px -> 21,807.)',
      );
    });
  });
}
