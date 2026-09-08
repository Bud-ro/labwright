import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
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
        final bytes = await rgbaOf(out);
        int lum(int x, int y) => bytes[(y * out.width + x) * 4];
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

  testWidgets('all icon-stamp geometry lands on whole logical pixels', (
    tester,
  ) async {
    final pngs = snippetCorpusPngs();
    await tester.runAsync(() async {
      final icons = await loadPrimIcons();
      var stamps = 0;
      for (final f in pngs) {
        final vi = extractSnippetVi(f.readAsBytesSync());
        if (vi == null) continue;
        final bd = bestBlockDiagram(buildViModel(vi));
        if (bd == null) continue;
        for (final o in bdDrawableObjects(bd)) {
          final b = o.absBounds;
          if (b == null) continue;
          final key = primIconKeyOf(o);
          final art = key == null ? null : icons[key];
          if (art == null) continue;
          stamps++;
          final stamp = primIconStampRect(
            ui.Rect.fromLTRB(
              b.left.toDouble(),
              b.top.toDouble(),
              b.right.toDouble(),
              b.bottom.toDouble(),
            ),
            art.base.width,
            art.base.height,
            key: key,
          );
          for (final v in [stamp.left, stamp.top, stamp.width, stamp.height]) {
            expect(
              v,
              v.truncateToDouble(),
              reason: 'fractional stamp geometry for $key in ${f.path}: $stamp',
            );
          }
          expect(
            stamp.width * stamp.height,
            greaterThan(0),
            reason: 'empty stamp for $key in ${f.path}',
          );
          final mask = await rgbaOf(art.base);
          final aw = art.base.width, ah = art.base.height;
          (int, int)? top, leftmost;
          for (var y = 0; y < ah && top == null; y++) {
            for (var x = 0; x < aw; x++) {
              if (mask[(y * aw + x) * 4 + 3] != 0) {
                top = (x, y);
                break;
              }
            }
          }
          for (var x = 0; x < aw && leftmost == null; x++) {
            for (var y = 0; y < ah; y++) {
              if (mask[(y * aw + x) * 4 + 3] != 0) {
                leftmost = (x, y);
                break;
              }
            }
          }
          expect(top, isNotNull, reason: 'fully transparent asset $key');
          final (tx, ty) = top!;
          final (lx, ly) = leftmost!;
          expect(
            primIconHit(o, stamp.left + tx + 0.5, stamp.top + ty + 0.5),
            isTrue,
            reason: 'hitbox misaligned with stamp for $key in ${f.path}',
          );
          expect(
            primIconHit(o, stamp.left + tx + 0.5, stamp.top + ty - 0.5),
            isFalse,
            reason: 'hitbox extends above stamp ink for $key in ${f.path}',
          );
          expect(
            primIconHit(o, stamp.left + lx + 0.5, stamp.top + ly + 0.5),
            isTrue,
            reason: 'hitbox misaligned (x) with stamp for $key in ${f.path}',
          );
          expect(
            primIconHit(o, stamp.left + lx - 0.5, stamp.top + ly + 0.5),
            isFalse,
            reason: 'hitbox extends left of stamp ink for $key in ${f.path}',
          );
        }
      }
      // ignore: avoid_print
      print('checked $stamps icon stamps across the snippet corpus');
    });
  }, tags: 'corpus');

  testWidgets('crc8 display pipeline: the U8 icon renders with uniform borders', (
    tester,
  ) async {
    final f = snippetPng('crc8.png');
    await loadRealTextFont();
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
      const n = 2;
      final display = await boxDownscale(fitted3, ss * n);
      final out = await rgbaOf(display);
      int lum(int x, int y) => out[(y * display.width + x) * 4];
      final o = bd.byId[894]!.absBounds!;
      final reg = result.registration;
      final art1608b = icons[1608]!.base;
      final stampRef = primIconStampRect(
        ui.Rect.fromLTRB(
          o.left - raster.content.left + reg.dx,
          o.top - raster.content.top + reg.dy,
          o.right - raster.content.left + reg.dx,
          o.bottom - raster.content.top + reg.dy,
        ),
        art1608b.width,
        art1608b.height,
        key: 1608,
      );
      final topRow = stampRef.top.toInt() ~/ n;
      final botRow = (stampRef.bottom.toInt() - 1) ~/ n;
      final xs = [
        for (
          var x = (stampRef.left.toInt() + 6 + n - 1) ~/ n;
          x <= (stampRef.right.toInt() - 7) ~/ n;
          x++
        )
          x,
      ];
      final bottom = [for (final x in xs) lum(x, botRow)];
      // ignore: avoid_print
      print('U8 bottom border row y=$botRow: $bottom');
      final botSpread =
          bottom.reduce((a, b) => a > b ? a : b) -
          bottom.reduce((a, b) => a < b ? a : b);
      expect(
        botSpread,
        lessThanOrEqualTo(2),
        reason: 'bottom border not uniform: $bottom',
      );
      expect(topRow * n, stampRef.top.toInt(), reason: 'row bookkeeping');

      final rasterPx = await rgbaOf(raster.image);
      final refPx = await rgbaOf(reference.image);
      String oursAt(int x, int y) {
        final i =
            ((y - raster.content.top).toInt() * raster.image.width +
                (x - raster.content.left).toInt()) *
            4;
        return '${rasterPx[i]},${rasterPx[i + 1]},${rasterPx[i + 2]}';
      }

      String refAt(int x, int y) {
        final i =
            ((y - raster.content.top + reg.dy).toInt() * reference.image.width +
                (x - raster.content.left + reg.dx).toInt()) *
            4;
        return '${refPx[i]},${refPx[i + 1]},${refPx[i + 2]}';
      }

      final greyIcons = primIconsGreyLoaded();
      for (final (label, key, oid, art) in [
        ('prim1608', 1608, 894, icons[1608]!.base),
        ('prim1900 disabled', 1900, 3081, greyIcons[1900]!.base),
      ]) {
        final b = bd.byId[oid]!.absBounds!;
        final stamp = primIconStampRect(
          ui.Rect.fromLTRB(
            b.left - raster.content.left,
            b.top - raster.content.top,
            b.right - raster.content.left,
            b.bottom - raster.content.top,
          ),
          art.width,
          art.height,
          key: key,
        );
        final artPx = await rgbaOf(art);
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
          '$label stamp at 1:1: $opaque opaque asset px, '
          '$mismatched mismatched',
        );
        expect(opaque, greaterThan(100));
        expect(
          mismatched,
          0,
          reason: '$label: the 1:1 stamp must reproduce the art exactly',
        );
      }

      final u8 = bd.byId[894]!.absBounds!;
      final u8cx = (u8.left + u8.right) / 2;
      ViPoint? exitPt, inputPt;
      for (final w in wires) {
        final rp = w.routePoints;
        if (rp == null) continue;
        for (var e = 0; e < w.endpointAnchors.length; e++) {
          final a = w.endpointAnchors[e];
          if (a == null ||
              a.left != u8.left ||
              a.top != u8.top ||
              a.right != u8.right ||
              a.bottom != u8.bottom) {
            continue;
          }
          final pt = e == 0 ? rp.first : rp.last;
          if (pt.x >= u8cx) {
            exitPt = pt;
          } else {
            inputPt = pt;
          }
        }
      }
      expect(exitPt, isNotNull, reason: 'the U8 op must ship an exit route');
      expect(inputPt, isNotNull, reason: 'the U8 op must ship an input route');
      Set<String> oursColumn(int x, int rowY) => {
        for (final y in [rowY - 1, rowY]) oursAt(x, y),
      };
      Set<String> refColumn(int x, int rowY) => {
        for (final y in [rowY - 1, rowY]) refAt(x, y),
      };
      final rightOf = oursColumn(exitPt!.x, exitPt.y);
      final leftOf = oursColumn(inputPt!.x, inputPt.y);
      // ignore: avoid_print
      print(
        'U8 exit route @(${exitPt.x},${exitPt.y}) ours=$rightOf '
        'ref=${refColumn(exitPt.x, exitPt.y)}; '
        'input route @(${inputPt.x},${inputPt.y}) ours=$leftOf '
        'ref=${refColumn(inputPt.x, inputPt.y)}',
      );
      expect(
        rightOf,
        contains('0,0,255'),
        reason: 'exit wire must meet the node and be integer blue',
      );
      expect(
        rightOf,
        refColumn(exitPt.x, exitPt.y),
        reason: 'exit wire must reproduce the reference at its connection',
      );
      expect(
        rightOf.difference({'0,0,255', '255,255,255'}),
        isEmpty,
        reason: 'exit wire must be a crisp 1px fill, no half-tones',
      );
      expect(
        leftOf,
        contains('255,0,255'),
        reason: 'input wire must meet the node and be string pink',
      );
      expect(
        leftOf,
        refColumn(inputPt.x, inputPt.y),
        reason: 'input wire must reproduce the reference at its connection',
      );

      // TODO: the structure band is not byte-faithful; its edge corridors are excluded from the surround check.
      final structureEdgeRects = [
        for (final o in drawable)
          if (o.category == ViObjectKind.structure) o.absBounds!,
      ];
      // Modeled structure-terminal boxes are excluded: which ones LabVIEW shows is not decoded.
      final modeledTerminalRects = [
        for (final e in bdStructureTerminals(bd).entries)
          for (final t in e.value)
            if (bd.byId[e.key]?.absBounds case final s?)
              (
                left: s.left + t.box.left,
                top: s.top + t.box.top,
                right: s.left + t.box.left + t.box.width,
                bottom: s.top + t.box.top + t.box.height,
              ),
      ];
      bool onStructureEdge(int x, int y) =>
          structureEdgeRects.any(
            (r) =>
                x >= r.left - 1 &&
                x < r.right + 1 &&
                y >= r.top - 1 &&
                y < r.bottom + 1 &&
                !(x >= r.left + 6 &&
                    x < r.right - 6 &&
                    y >= r.top + 6 &&
                    y < r.bottom - 6),
          ) ||
          modeledTerminalRects.any(
            (r) =>
                x >= r.left - 1 &&
                x < r.right + 1 &&
                y >= r.top - 1 &&
                y < r.bottom + 1,
          );
      const canvasWhite = '255,255,255';
      final chromeCounts = <int, int>{};
      var bandCompared = 0;
      for (final w in wires) {
        for (var e = 0; e < w.endpointAttachRects.length; e++) {
          final attach = w.endpointAttachRects[e];
          if (attach == null) continue;
          final terminal = bd.endpointTerminal(w.endpointOids[e]);
          final kind = terminal?.kind;
          if (kind == null || !kVerifiedBorderTerminalKinds.contains(kind)) {
            continue;
          }
          chromeCounts[kind] = (chromeCounts[kind] ?? 0) + 1;
          var mismatched = 0;
          var bleed = 0;
          for (var y = attach.top - 2; y < attach.bottom + 2; y++) {
            for (var x = attach.left - 2; x < attach.right + 2; x++) {
              final inside =
                  x >= attach.left &&
                  x < attach.right &&
                  y >= attach.top &&
                  y < attach.bottom;
              if (inside) {
                if (oursAt(x, y) != refAt(x, y)) mismatched++;
              } else if (!onStructureEdge(x, y)) {
                bandCompared++;
                if (refAt(x, y) == canvasWhite && oursAt(x, y) != canvasWhite) {
                  bleed++;
                }
              }
            }
          }
          expect(
            mismatched,
            0,
            reason:
                'terminal 0x${kind.toRadixString(16)} at (${attach.left},'
                '${attach.top}) differs from the reference in $mismatched px',
          );
          expect(
            bleed,
            0,
            reason:
                'terminal 0x${kind.toRadixString(16)} at (${attach.left},'
                '${attach.top}): $bleed px of ink bleed onto reference-white '
                'canvas in its 2 px surround band',
          );
        }
      }
      expect(bandCompared, greaterThan(1000));
      // ignore: avoid_print
      print(
        'chrome byte-verified vs reference: '
        '${chromeCounts.entries.map((e) => '0x${e.key.toRadixString(16)} x${e.value}').join(', ')}',
      );
      expect(chromeCounts.keys.toSet(), {0x22, 0x2d, 0x27, 0x28, 0x2e});

      final leafRects = [
        for (final o in drawable)
          if (o.category != ViObjectKind.structure && o.absBounds != null)
            o.absBounds!,
        for (final w in wires) ...w.endpointAttachRects.whereType<HeapRect>(),
      ];
      bool covered(int x, int y) => leafRects.any(
        (r) => x >= r.left && x < r.right && y >= r.top && y < r.bottom,
      );
      int mismatchesAlong(ViWire w, {required int minCompared}) {
        final rp = w.routePoints!;
        var compared = 0, mismatched = 0;
        for (var i = 0; i + 1 < rp.length; i++) {
          final a = rp[i], b = rp[i + 1];
          final horizontal = a.y == b.y;
          final lo = (horizontal ? min(a.x, b.x) : min(a.y, b.y)) + 12;
          final hi = (horizontal ? max(a.x, b.x) : max(a.y, b.y)) - 12;
          final cross = horizontal ? a.y : a.x;
          for (var v = lo; v <= hi; v++) {
            for (var d = -2; d <= 2; d++) {
              final (x, y) = horizontal ? (v, cross + d) : (cross + d, v);
              if (covered(x, y)) continue;
              final ri =
                  (((y - raster.content.top).toInt()) * raster.image.width +
                      (x - raster.content.left).toInt()) *
                  4;
              final fi =
                  ((y - raster.content.top + reg.dy).toInt() *
                          reference.image.width +
                      (x - raster.content.left + reg.dx).toInt()) *
                  4;
              compared++;
              if (rasterPx[ri] != refPx[fi] ||
                  rasterPx[ri + 1] != refPx[fi + 1] ||
                  rasterPx[ri + 2] != refPx[fi + 2]) {
                mismatched++;
              }
            }
          }
        }
        expect(
          compared,
          greaterThan(minCompared),
          reason: 'sig ${w.signalOid}',
        );
        // ignore: avoid_print
        print(
          'wire sig ${w.signalOid}: $compared band px byte-compared, '
          '$mismatched mismatched',
        );
        return mismatched;
      }

      for (final sig in [403, 1831, 921]) {
        final w = wires.singleWhere((w) => w.signalOid == sig);
        expect(w.routePoints, isNotNull, reason: 'sig $sig must ship a route');
        expect(
          mismatchesAlong(w, minCompared: 500),
          0,
          reason: 'sig $sig: routed wire must reproduce the reference bytes',
        );
      }

      String at(
        Uint8List px,
        int imgW,
        int x,
        int y, {
        int dx = 0,
        int dy = 0,
      }) {
        final i = ((y + dy) * imgW + x + dx) * 4;
        return '${px[i]},${px[i + 1]},${px[i + 2]}';
      }

      var crossCompared = 0;
      for (var y = 293; y <= 301; y++) {
        for (var x = 500; x <= 505; x++) {
          final ours = at(
            rasterPx,
            raster.image.width,
            (x - raster.content.left).toInt(),
            (y - raster.content.top).toInt(),
          );
          final ref = at(
            refPx,
            reference.image.width,
            (x - raster.content.left + reg.dx).toInt(),
            (y - raster.content.top + reg.dy).toInt(),
          );
          crossCompared++;
          expect(ours, ref, reason: 'crossing pixel ($x,$y)');
        }
      }
      expect(crossCompared, 54);
      String ours(int x, int y) => at(
        rasterPx,
        raster.image.width,
        (x - raster.content.left).toInt(),
        (y - raster.content.top).toInt(),
      );
      const blue = '0,0,255', green = '0,102,0', white = '255,255,255';
      expect(ours(502, 295), blue);
      expect(ours(503, 295), blue);
      expect(ours(502, 299), blue);
      expect(ours(503, 299), blue);
      expect(ours(502, 296), white);
      expect(ours(503, 296), white);
      expect(ours(502, 298), white);
      expect(ours(503, 298), white);
      expect(ours(503, 297), green);
      expect(ours(502, 297), white);

      final constBox = bd.byId[3033]!.absBounds!;
      var borderPx = 0, borderMismatched = 0, dimBlue = 0;
      for (var y = constBox.top; y < constBox.bottom; y++) {
        for (var x = constBox.left; x < constBox.right; x++) {
          final onBorder =
              x < constBox.left + 2 ||
              x >= constBox.right - 2 ||
              y < constBox.top + 2 ||
              y >= constBox.bottom - 2;
          if (!onBorder) continue;
          borderPx++;
          if (oursAt(x, y) != refAt(x, y)) borderMismatched++;
          if (oursAt(x, y) == '153,153,255') dimBlue++;
        }
      }
      // ignore: avoid_print
      print('oid3033 border: $borderPx px, $borderMismatched mismatched');
      expect(borderPx, 160);
      expect(borderMismatched, 0, reason: 'oid3033 border vs reference');
      expect(dimBlue, borderPx, reason: 'the whole border is dim blue');
      var valueInk = 0;
      for (var y = constBox.top + 2; y < constBox.bottom - 2; y++) {
        for (var x = constBox.left + 2; x < constBox.right - 2; x++) {
          final v = oursAt(x, y);
          if (v == white) continue;
          valueInk++;
          final c = v.split(',').map(int.parse).toList();
          expect(c[0] == c[1] && c[1] == c[2], isTrue, reason: 'chromatic $v');
          expect(c[0], greaterThanOrEqualTo(153), reason: 'undimmed ink $v');
        }
      }
      expect(valueInk, greaterThan(30), reason: 'the 256 literal must draw');
      for (final (x, y) in [
        (constBox.left + 3, constBox.top + 3),
        (constBox.right - 4, constBox.top + 3),
        (constBox.left + 3, constBox.bottom - 4),
        (constBox.right - 4, constBox.bottom - 4),
      ]) {
        expect(oursAt(x, y), white, reason: 'inner-ring pixel ($x,$y)');
      }

      final w1988 = wires.singleWhere((w) => w.endpointOids.contains(1988));
      expect(
        w1988.routePoints,
        isNotNull,
        reason: 'oid1988 wire must ship a route',
      );
      expect(
        w1988.routeClosingStep,
        (dx: 1, dy: 0),
        reason: 'its implied closing run enters oid902 rightward',
      );
      final without = (await rasteriseBlockDiagram(
        bd,
        primIcons: icons,
        scale: 1.0,
        margin: 2,
        wires: [
          for (final w in wires)
            if (w.signalOid != w1988.signalOid) w,
        ],
        drawable: drawable,
      ))!;
      expect(without.content, raster.content, reason: 'same content frame');
      final woPx = await rgbaOf(without.image);
      String woAt(int x, int y) {
        final i =
            ((y - raster.content.top).toInt() * without.image.width +
                (x - raster.content.left).toInt()) *
            4;
        return '${woPx[i]},${woPx[i + 1]},${woPx[i + 2]}';
      }

      final rp = w1988.routePoints!;
      final cl = raster.content.left.toInt(), ct = raster.content.top.toInt();
      final mask = <int>{};
      var maskCount = 0, maskMismatched = 0;
      for (var y = ct; y < ct + raster.image.height; y++) {
        for (var x = cl; x < cl + raster.image.width; x++) {
          if (oursAt(x, y) == woAt(x, y)) continue;
          mask.add((y - ct) * raster.image.width + (x - cl));
          maskCount++;
          if (oursAt(x, y) != refAt(x, y)) maskMismatched++;
        }
      }
      // ignore: avoid_print
      print('oid1988 wire mask: $maskCount px, $maskMismatched off reference');
      expect(maskCount, greaterThan(400), reason: 'the wire draws a long run');
      expect(
        maskMismatched,
        0,
        reason: 'every drawn oid1988 wire pixel must equal the reference',
      );
      final wireColor = refAt((rp[0].x + rp[1].x) ~/ 2, rp[0].y);
      expect(wireColor, isNot(canvasWhite), reason: 'the wire leg is inked');
      bool inMask(int x, int y) =>
          mask.contains((y - ct) * raster.image.width + (x - cl));
      final termBox = w1988.endpointAnchors[0]!;
      var wireInkCovered = 0;
      void coverAlong(int x, int y) {
        if (x >= termBox.left &&
            x < termBox.right &&
            y >= termBox.top &&
            y < termBox.bottom) {
          return;
        }
        if (refAt(x, y) != wireColor) return;
        if (inMask(x, y)) {
          wireInkCovered++;
          return;
        }
        expect(
          woAt(x, y),
          wireColor,
          reason: 'reference wire ink at ($x,$y) undrawn (no crossing wire)',
        );
      }

      for (var s = 0; s + 1 < rp.length; s++) {
        final a = rp[s], b = rp[s + 1];
        final horizontal = a.y == b.y;
        final lo = horizontal ? min(a.x, b.x) : min(a.y, b.y);
        final hi = horizontal ? max(a.x, b.x) : max(a.y, b.y);
        for (var v = lo; v <= hi; v++) {
          coverAlong(horizontal ? v : a.x, horizontal ? a.y : v);
        }
      }
      final step = w1988.routeClosingStep!;
      final farBox = w1988.endpointAnchors[1]!;
      var cx = rp.last.x + step.dx, cy = rp.last.y + step.dy;
      var closingRun = 0;
      while (cx >= farBox.left &&
          cx <= farBox.right &&
          cy >= farBox.top &&
          cy <= farBox.bottom &&
          refAt(cx, cy) == wireColor) {
        coverAlong(cx, cy);
        closingRun++;
        cx += step.dx;
        cy += step.dy;
      }
      expect(
        closingRun,
        greaterThan(0),
        reason: 'the closing run reaches oid902 before its art begins',
      );
      expect(
        wireInkCovered,
        greaterThan(600),
        reason: 'the horizontal, vertical, and closing legs are all covered',
      );
      // ignore: avoid_print
      print(
        'oid1988 wire coverage: $wireInkCovered ink px (closing run $closingRun)',
      );

      bool isDark(String rgb) {
        final c = rgb.split(',').map(int.parse).toList();
        return c[0] < 160 && c[1] < 160 && c[2] < 160;
      }

      int mass(String rgb) {
        final c = rgb.split(',').map(int.parse).toList();
        return 255 - (c[0] * 299 + c[1] * 587 + c[2] * 114) ~/ 1000;
      }

      final xorLabel = bd.byId[221]!;
      expect(xorLabel.label, 'XOR?');
      final xbox = xorLabel.absBounds!;
      var xorInk = 0, xorMass = 0, xorRefMass = 0;
      for (var y = xbox.top; y < xbox.bottom; y++) {
        for (var x = xbox.left; x < xbox.right; x++) {
          if (isDark(oursAt(x, y))) xorInk++;
          xorMass += mass(oursAt(x, y));
          xorRefMass += mass(refAt(x, y));
        }
      }
      // ignore: avoid_print
      print('XOR? caption ink: dark=$xorInk mass=$xorMass ref=$xorRefMass');
      expect(
        xorInk,
        greaterThan(20),
        reason: 'the XOR? caption must render as text ink',
      );
      expect(
        xorMass / xorRefMass,
        closeTo(1.0, 0.25),
        reason: 'the XOR? ink mass must track the reference caption',
      );

      bool isInk(String rgb) => rgb != '255,255,255';
      for (final (sig, value) in [(375, 8), (3126, 256), (399, 256)]) {
        final w = wires.firstWhere((w) => w.signalOid == sig);
        expect(
          bd.endpointConstant(w.endpointOids[0])?.constNumeric,
          value,
          reason: 'feeder $sig must wrap the $value constant',
        );
        final box = w.endpointAnchors[0]!;
        final term = w.endpointAttachRects[1]!;
        final row = (box.top + box.bottom) ~/ 2;
        var span = 0, refInkSpan = 0, rasterInkSpan = 0;
        for (var x = box.right.toInt(); x <= term.left.toInt(); x++) {
          span++;
          var refHit = false, rasterHit = false;
          for (var dy = -1; dy <= 1; dy++) {
            if (isInk(refAt(x, row + dy))) refHit = true;
            if (isInk(oursAt(x, row + dy))) rasterHit = true;
          }
          if (refHit) refInkSpan++;
          if (rasterHit) rasterInkSpan++;
        }
        // ignore: avoid_print
        print(
          'feeder $sig (const $value) span=$span '
          'refInk=$refInkSpan rasterInk=$rasterInkSpan',
        );
        expect(
          refInkSpan,
          span,
          reason: 'the reference wires the $value constant box to its terminal',
        );
        expect(
          rasterInkSpan,
          span,
          reason: 'the render must route the $value feeder to the constant box',
        );
      }
    });
  });

  testWidgets('branch-wire routeTree runs + junction dots land on ref ink', (
    tester,
  ) async {
    final root = repoDir('packages/labwright_rsrc_parse/corpus/vi');
    await loadRealTextFont();
    var branchWires = 0, junctionDots = 0, runPixels = 0, exposedWires = 0;
    await tester.runAsync(() async {
      final icons = await loadPrimIcons();
      for (final name in ['Excel_Read_XLSX', 'Read VI Blocks']) {
        final file = root
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('/$name.png'));
        final bytes = file.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final drawable = bdDrawableObjects(bd);
        final wires = bdVisibleWires(bd);
        final phaseScene = BdScene(bd, wires: wires, drawable: drawable);
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
        final reg = result.registration;
        final rephased = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          margin: 2,
          wires: wires,
          drawable: drawable,
          style: BdRenderStyle(
            wireCycleOffset: deriveWireCycleOffset(
              scene: phaseScene,
              raster: raster,
              registration: reg,
              referenceRgba: result.referenceRgba,
              width: reference.image.width,
              height: reference.image.height,
            ),
          ),
        ))!;
        final refPx = await rgbaOf(reference.image);
        final rasterPx = await rgbaOf(rephased.image);
        final rw = reference.image.width;
        final aw = rephased.image.width, ah = rephased.image.height;

        final maskRects = <ui.Rect>[
          for (final o in drawable)
            if (o.absBounds != null)
              ui.Rect.fromLTRB(
                o.absBounds!.left - raster.content.left - 3,
                o.absBounds!.top - raster.content.top - 3,
                o.absBounds!.right - raster.content.left + 3,
                o.absBounds!.bottom - raster.content.top + 3,
              ),
        ];
        bool masked(int x, int y) {
          final p = Offset(x.toDouble(), y.toDouble());
          for (final r in maskRects) {
            if (r.contains(p)) return true;
          }
          return false;
        }

        bool ink(Uint8List px, int stride, int ox, int oy, int x, int y) {
          for (var dy = -1; dy <= 1; dy++) {
            final xx = x + ox, yy = y + oy + dy;
            if (xx < 0 || yy < 0) continue;
            final i = (yy * stride + xx) * 4;
            if (i < 0 || i + 2 >= px.length) continue;
            if (!(px[i] > 210 && px[i + 1] > 210 && px[i + 2] > 210))
              return true;
          }
          return false;
        }

        for (final w in wires) {
          final tree = w.routeTree;
          if (tree == null) continue;
          branchWires++;
          final run = <(int, int)>{};
          for (final poly in tree.polylines) {
            for (var i = 1; i < poly.length; i++) {
              final a = poly[i - 1], b = poly[i];
              if (a.y == b.y) {
                final lo = a.x < b.x ? a.x : b.x, hi = a.x < b.x ? b.x : a.x;
                for (var x = lo; x <= hi; x++) {
                  run.add((
                    (x - raster.content.left).toInt(),
                    (a.y - raster.content.top).toInt(),
                  ));
                }
              } else {
                final lo = a.y < b.y ? a.y : b.y, hi = a.y < b.y ? b.y : a.y;
                for (var y = lo; y <= hi; y++) {
                  run.add((
                    (a.x - raster.content.left).toInt(),
                    (y - raster.content.top).toInt(),
                  ));
                }
              }
            }
          }
          var runExposed = 0, runRefInk = 0, runRasterInk = 0;
          for (final (x, y) in run) {
            if (x < 0 || y < 0 || x >= aw || y >= ah) continue;
            if (masked(x, y)) continue;
            runExposed++;
            if (ink(refPx, rw, reg.dx.toInt(), reg.dy.toInt(), x, y)) {
              runRefInk++;
            }
            if (ink(rasterPx, aw, 0, 0, x, y)) runRasterInk++;
          }
          runPixels += runExposed;
          // ignore: avoid_print
          print(
            '$name branch ${w.signalOid}: run exposed=$runExposed '
            'refInk=$runRefInk rasterInk=$runRasterInk',
          );
          if (runExposed > 0) {
            exposedWires++;
            expect(
              runRefInk / runExposed,
              greaterThanOrEqualTo(0.98),
              reason:
                  '$name ${w.signalOid}: runs must land on reference wire ink',
            );
            expect(
              runRasterInk / runExposed,
              greaterThanOrEqualTo(0.98),
              reason: '$name ${w.signalOid}: the render must draw every run',
            );
          }
          final sigStyle =
              w.signalType?.renderStyle ?? w.signalType?.renderStyleEstimate;
          if (sigStyle == ViWireRenderStyle.solid2px ||
              (sigStyle == null && (w.signalType?.arrayDims ?? 0) >= 1)) {
            continue;
          }
          for (final j in tree.junctions) {
            var dotExposed = 0, dotRefInk = 0, dotRasterInk = 0;
            for (var dy = -2; dy <= 2; dy++) {
              for (var dx = -2; dx <= 2; dx++) {
                if (dx.abs() == 2 && dy.abs() == 2) continue;
                final x = (j.x + dx - raster.content.left).toInt();
                final y = (j.y + dy - raster.content.top).toInt();
                if (x < 0 || y < 0 || x >= aw || y >= ah) continue;
                if (masked(x, y)) continue;
                dotExposed++;
                if (ink(refPx, rw, reg.dx.toInt(), reg.dy.toInt(), x, y)) {
                  dotRefInk++;
                }
                if (ink(rasterPx, aw, 0, 0, x, y)) dotRasterInk++;
              }
            }
            if (dotExposed == 0) continue;
            junctionDots++;
            // ignore: avoid_print
            print(
              '$name junction (${j.x},${j.y}): exposed=$dotExposed '
              'refInk=$dotRefInk rasterInk=$dotRasterInk',
            );
            expect(dotExposed, greaterThan(12));
            expect(
              dotRefInk,
              dotExposed,
              reason: 'junction dot must land wholly on reference wire ink',
            );
            expect(
              dotRasterInk,
              dotExposed,
              reason: 'the render must stamp the whole junction dot',
            );
          }
        }
        phaseScene.dispose();
      }
    });
    // ignore: avoid_print
    print(
      'branch wires verified: $branchWires ($exposedWires exposed, with '
      '$junctionDots junction dots, $runPixels run px)',
    );
    expect(branchWires, greaterThanOrEqualTo(2));
    expect(junctionDots, greaterThanOrEqualTo(2));
    expect(exposedWires, greaterThanOrEqualTo(2));
    expect(runPixels, greaterThan(2000));
  }, tags: 'corpus');

  testWidgets('CrispImage shows the base at n:1 and the box-downscaled '
      'supersample below it', (tester) async {
    final base = await tester.runAsync(
      () => _fromRgba(Uint8List(10 * 10 * 4)..fillRange(0, 400, 255), 10, 10),
    );
    final ss = await tester.runAsync(
      () => _fromRgba(Uint8List(30 * 30 * 4)..fillRange(0, 3600, 255), 30, 30),
    );
    Future<void> pumpPane(Size size) => pumpBody(
      tester,
      Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: CrispImage(ss!, supersample: 3, base: base),
        ),
      ),
      view: const Size(100, 100),
    );

    for (final size in const [Size(10, 10), Size(25, 25)]) {
      await pumpPane(size);
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image, same(base), reason: 'pane $size');
    }

    await tester.runAsync(() async {
      await pumpPane(const Size(4, 4));
      for (var i = 0; i < 40 && find.byType(RawImage).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
      }
    });
    final minified = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(minified, isNot(same(base)));
    expect(minified, isNot(same(ss)));
    expect((minified!.width, minified.height), (3, 3), reason: '30 px / 9');
  });
}
