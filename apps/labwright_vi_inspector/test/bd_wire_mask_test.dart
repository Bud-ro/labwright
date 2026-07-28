import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// PER-WIRE masked-pixel convergence on Excel_Read_XLSX — the ratchet that
/// grows the "known perfect" region of the render wire by wire.
///
/// For every drawn wire the diagram is re-rasterised WITHOUT it; the pixels
/// that change are that wire's own visible ink (runs covered by icons or by
/// sibling wires cancel out of the mask). Each masked pixel must reproduce
/// the reference byte-for-byte; a wire with zero mismatches is PERFECT.
///
/// The floors below are exact-state pins, not aspirations: a change that
/// makes a perfect wire imperfect fails here. When a fix (or new routing)
/// moves the counts, re-pin to the measured value and PROVE the delta
/// against reference ink — never loosen. The same leave-one-out technique
/// is the template for pinning every other drawn element class later.
///
/// Known imperfect remainder (100 px over 15 wires at pin time): the braid
/// T-junction art (sig 534), a prim stub whose output type is uncatalogued
/// (2398), wire ink under the film-strip band (2806/495), crossing gaps
/// against still-unrouted wires (5458/6282), patterned-band junction shapes
/// (4838), bend-corner pattern trims, and anti-aliased chrome (terminal
/// arrows) blending over wire ink.
void main() {
  testWidgets('Excel per-wire masks: 64 of 79 drawn wires are byte-perfect', (
    tester,
  ) async {
    final dir = repoDir(
      'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
    );
    if (dir == null) {
      markTestSkipped('corpus not fetched');
      return;
    }
    final f = dir
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((x) => x.path.endsWith('/Excel_Read_XLSX.png'));
    final bytes = f.readAsBytesSync();
    final viBytes = extractSnippetVi(bytes)!;
    final bd = bestBlockDiagram(buildViModel(viBytes))!;
    final scene = BdScene(bd);
    await loadRealTextFont();
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
        anchorRects: bdStructureAnchorRects(
          bd,
          raster,
          drawable: scene.drawable,
        ),
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
      // ignore: avoid_print
      print('derived wireCycleOffset=$wirePhase');
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
      // ignore: avoid_print
      print(
        'wire masks: drawn=$drawn perfect=$perfect offPx=$totalOff '
        '${imperfect.join(" ")}',
      );
      expect(drawn, greaterThanOrEqualTo(79), reason: 'drawn-wire floor');
      expect(
        perfect,
        greaterThanOrEqualTo(64),
        reason:
            'byte-perfect wire floor — a regression here un-fixes a wire '
            'that matched LabVIEW exactly',
      );
      expect(
        totalOff,
        lessThanOrEqualTo(100),
        reason:
            'off-reference pixel ceiling over all wire masks — re-pin '
            'DOWNWARD as decodes land, never up',
      );
    });
  });
}
