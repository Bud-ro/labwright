import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

Future<ui.Image> _fromRgba(Uint8List rgba, int w, int h) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// The oracle display path may only produce PHASE-FREE pixels: a 1 px line
/// keeps one thickness wherever it sits, a checkerboard downscales to one
/// uniform grey. These tests measure actual output pixels — synthetic first,
/// then the real crc8 pipeline end to end.
void main() {
  test(
    'boxDownscale is phase-free: 1px lines and checkerboards land uniform',
    () async {
      const w = 64, h = 64;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = 255;
      }
      void set(int x, int y, int v) {
        final i = (y * w + x) * 4;
        rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
      }

      // A 1px black line at EVERY row parity (y=9 odd-start, y=20 even-start),
      // and a 1px checkerboard band.
      for (var x = 0; x < w; x++) {
        set(x, 9, 0);
        set(x, 20, 0);
      }
      for (var y = 30; y < 40; y++) {
        for (var x = 0; x < w; x++) {
          set(x, y, (x + y) % 2 == 0 ? 0 : 255);
        }
      }
      final src = await _fromRgba(rgba, w, h);
      for (final k in [2, 3, 4]) {
        final out = await boxDownscale(src, k);
        final bytes = (await out.toByteData())!.buffer.asUint8List();
        int lum(int x, int y) => bytes[(y * out.width + x) * 4];
        // Every downscaled row that intersects a source line must be uniform
        // across its full width, and the total line "mass" must be conserved
        // per column (no widening/shrinking anywhere).
        for (final lineY in [9, 20]) {
          final rows = {lineY ~/ k, (lineY + k - 1) ~/ k};
          for (var x = 0; x < out.width; x++) {
            var mass = 0;
            for (final ry in rows) {
              mass += 255 - lum(x, ry);
            }
            final mass0 = [
              for (final ry in rows) 255 - lum(0, ry),
            ].reduce((a, b) => a + b);
            expect(
              mass,
              mass0,
              reason:
                  'k=$k line y=$lineY column $x mass differs — phase-dependent',
            );
          }
        }
        // The checkerboard invariant: when the checker period (2) divides k,
        // every block holds the same ink and the region is ONE grey; at odd k
        // the blocks hold 4/9 vs 5/9 ink — TWO greys in strict alternation
        // (regular and faithful, unlike phase-dependent widening).
        final vals = <int>{};
        final rows = <List<int>>[];
        for (var y = (30 / k).ceil(); y < 40 ~/ k - 1; y++) {
          final row = [for (var x = 1; x < out.width - 1; x++) lum(x, y)];
          rows.add(row);
          vals.addAll(row);
        }
        if (k.isEven) {
          expect(
            vals.length,
            1,
            reason: 'k=$k checkerboard not uniform: $vals',
          );
        } else {
          expect(
            vals.length,
            2,
            reason: 'k=$k expects two alternating greys: $vals',
          );
          for (final row in rows) {
            for (var i = 2; i < row.length; i++) {
              expect(
                row[i],
                row[i - 2],
                reason: 'k=$k alternation broke at $i: $row',
              );
            }
          }
        }
      }
    },
  );

  testWidgets(
    'crc8 display pipeline: the U8 icon renders with uniform borders',
    (tester) async {
      final dir = repoDir(
        'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
      );
      if (dir == null) {
        markTestSkipped('corpus not fetched');
        return;
      }
      await loadRealTextFont();
      final f = dir
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('/crc8.png'));
      await tester.runAsync(() async {
        final bytes = f.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final drawable = bdDrawableObjects(bd);
        final wires = bdVisibleWires(bd);
        final icons = await loadPrimIcons();
        final raster = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          margin: 2,
          wires: wires,
          drawable: drawable,
        ))!;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
        );
        const ss = kOracleDisplaySupersample;
        final raster3 = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: ss.toDouble(),
          margin: 2,
          wires: wires,
          drawable: drawable,
        ))!;
        final fitted3 = await redrawRegisteredSupersampled(
          raster3.image,
          result.registration,
          reference.image.width,
          reference.image.height,
          ss,
        );
        // Simulate a pane at half logical scale: n=2 -> k = 3*2.
        const n = 2;
        final display = await boxDownscale(fitted3, ss * n);
        final out = (await display.toByteData())!.buffer.asUint8List();
        int lum(int x, int y) => out[(y * display.width + x) * 4];
        // oid 894 (the U8 conversion) at diag (264,465)-(296,497); locate the
        // icon's border rows EMPIRICALLY: within a window around the node
        // centre, the first and last rows holding a long dark run are the
        // icon's top and bottom borders.
        final o = bd.byId[894]!.absBounds!;
        final reg = result.registration;
        final cx = (((o.left + o.right) / 2 + reg.dx) / n).round();
        final cy = (((o.top + o.bottom) / 2 + reg.dy) / n).round();
        List<int>? runAt(int y) {
          final xs = <int>[];
          for (var x = cx - 12; x <= cx + 12; x++) {
            if (lum(x, y) < 140) xs.add(x);
          }
          return xs.length >= 6 ? xs : null;
        }

        int? topRow, botRow;
        for (var y = cy - 8; y <= cy + 8; y++) {
          if (runAt(y) != null) {
            topRow ??= y;
            botRow = y;
          }
        }
        expect(topRow, isNotNull, reason: 'icon not found near ($cx,$cy)');
        // The run's endpoints are the icon's corner brackets (legitimately
        // denser ink) — uniformity is asserted over the border interior.
        final topXs = runAt(topRow!)!.sublist(1, runAt(topRow)!.length - 1);
        final botXs = runAt(botRow!)!.sublist(1, runAt(botRow)!.length - 1);
        final top = [for (final x in topXs) lum(x, topRow)];
        final bottom = [for (final x in botXs) lum(x, botRow)];
        // ignore: avoid_print
        print('U8 top border row y=$topRow: $top');
        // ignore: avoid_print
        print('U8 bottom border row y=$botRow: $bottom');
        final topSpread =
            top.reduce((a, b) => a > b ? a : b) -
            top.reduce((a, b) => a < b ? a : b);
        final botSpread =
            bottom.reduce((a, b) => a > b ? a : b) -
            bottom.reduce((a, b) => a < b ? a : b);
        expect(
          topSpread,
          lessThanOrEqualTo(2),
          reason: 'top border not uniform: $top',
        );
        expect(
          botSpread,
          lessThanOrEqualTo(2),
          reason: 'bottom border not uniform: $bottom',
        );

        // At the wipe's default 1x zoom the display IS the 1:1 raster, so
        // exactness reduces to the stamp itself: every opaque pixel of the
        // prim1608 asset must appear in the raster byte-for-byte at the
        // grid-aligned stamp rect. Zero tolerance.
        final art = icons[1608]!.base;
        final stamp = primIconStampRect(
          ui.Rect.fromLTRB(
            o.left - raster.content.left,
            o.top - raster.content.top,
            o.right - raster.content.left,
            o.bottom - raster.content.top,
          ),
          art.width,
          art.height,
        );
        final artPx = (await art.toByteData())!.buffer.asUint8List();
        final rasterPx = (await raster.image.toByteData())!.buffer
            .asUint8List();
        var opaque = 0, mismatched = 0;
        for (var y = 0; y < art.height; y++) {
          for (var x = 0; x < art.width; x++) {
            final a = (y * art.width + x) * 4;
            if (artPx[a + 3] == 0) continue;
            opaque++;
            final rx = stamp.left.toInt() + x;
            final ry = stamp.top.toInt() + y;
            final r = (ry * raster.image.width + rx) * 4;
            if (artPx[a] != rasterPx[r] ||
                artPx[a + 1] != rasterPx[r + 1] ||
                artPx[a + 2] != rasterPx[r + 2]) {
              mismatched++;
            }
          }
        }
        // ignore: avoid_print
        print(
          'U8 stamp at 1:1: $opaque opaque asset px, $mismatched mismatched',
        );
        expect(opaque, greaterThan(100));
        expect(
          mismatched,
          0,
          reason: 'the 1:1 stamp must reproduce the asset exactly',
        );
      });
    },
  );
}
