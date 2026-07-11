import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
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

  testWidgets('all icon-stamp geometry lands on whole logical pixels', (
    tester,
  ) async {
    final dir = repoDir(
      'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
    );
    if (dir == null) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await tester.runAsync(() async {
      final icons = await loadPrimIcons();
      var stamps = 0;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.png')) continue;
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
          // The alpha hitbox must sit exactly on the stamp: find the
          // topmost opaque pixel (whatever row it is on) — a hit at its
          // centre, a miss one pixel above it; and the same for the
          // leftmost opaque pixel on the horizontal axis.
          final mask = (await art.base.toByteData())!.buffer.asUint8List();
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
      expect(stamps, greaterThan(100));
    });
  });

  testWidgets('crc8 display pipeline: the U8 icon renders with uniform borders', (
    tester,
  ) async {
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
      // oid 894 (the U8 conversion): its stamp is KNOWN geometry
      // ([kPrimIconPlacement]), so the display rows holding its 1 px top
      // and bottom borders are computable exactly. At n=2 each display row
      // is the box mean of two logical rows — the border blends with its
      // neighbour, but UNIFORMLY: any spread along the row is phase error.
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
          // Clear the chamfered corners (borders descend through the top
          // rows for ~5 columns each side) so only the flat border mixes.
          var x = (stampRef.left.toInt() + 6 + n - 1) ~/ n;
          x <= (stampRef.right.toInt() - 7) ~/ n;
          x++
        )
          x,
      ];
      // Only the BOTTOM border blends with a uniform neighbour (canvas
      // white below); the top border mixes with the icon's own checker
      // content, so its display row varies legitimately. The synthetic
      // test above pins the both-parity 1 px line invariant; this pins it
      // in the real pipeline.
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

      // At the wipe's default integer zooms the display IS the 1:1 raster
      // (or its whole-pixel upscale), so exactness reduces to the stamp
      // itself: every opaque pixel of the art must appear in the raster
      // byte-for-byte at the grid-aligned stamp rect. Zero tolerance.
      // Three stamps cover the three paths: a normal primitive (prim1608),
      // a node in a DISABLED frame drawn with the grey-palette variant
      // (prim1900, oid 3081), and a single-op class icon (class185,
      // oid 3306).
      final rasterPx = (await raster.image.toByteData())!.buffer.asUint8List();
      final greyIcons = primIconsGreyLoaded();
      for (final (label, key, oid, art) in [
        ('prim1608', 1608, 894, icons[1608]!.base),
        ('prim1900 disabled', 1900, 3081, greyIcons[1900]!.base),
        ('class185', -185, 3306, icons[-185]!.base),
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
        final artPx = (await art.toByteData())!.buffer.asUint8List();
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

      // The U8 conversion's wires: both must TOUCH the stamped icon (the
      // route anchors substitute the stamp rect for the model box), and
      // the exit wire carries the op's catalogued output colour — integer
      // blue, from [PrimOp.output] — while the input stays string pink
      // from its typed source terminal.
      final u8 = bd.byId[894]!.absBounds!;
      final art1608 = icons[1608]!.base;
      final stamp1608 = primIconStampRect(
        ui.Rect.fromLTRB(
          u8.left - raster.content.left,
          u8.top - raster.content.top,
          u8.right - raster.content.left,
          u8.bottom - raster.content.top,
        ),
        art1608.width,
        art1608.height,
        key: 1608,
      );
      Set<String> colorsAt(int x, List<int> ys) => {
        for (final y in ys)
          [
            for (var c = 0; c < 3; c++)
              rasterPx[(y * raster.image.width + x) * 4 + c],
          ].join(','),
      };
      final wireYs = [
        stamp1608.center.dy.floor() - 1,
        stamp1608.center.dy.floor(),
        stamp1608.center.dy.ceil(),
      ];
      final rightOf = colorsAt(stamp1608.right.toInt(), wireYs);
      final leftOf = colorsAt(stamp1608.left.toInt() - 1, wireYs);
      // ignore: avoid_print
      print('U8 wire px right of icon: $rightOf, left of icon: $leftOf');
      expect(
        rightOf,
        contains('0,0,255'),
        reason: 'exit wire must touch the icon and be integer blue',
      );
      // 1 px crispness: nothing but pure wire colour and canvas white may
      // appear in the sampled band — a stroked centreline at integer
      // coordinates half-covers two rows (solid core + half-tones).
      expect(
        rightOf.difference({'0,0,255', '255,255,255'}),
        isEmpty,
        reason: 'exit wire must be a crisp 1px fill, no half-tones',
      );
      expect(
        leftOf,
        contains('255,0,255'),
        reason: 'input wire must touch the icon and be string pink',
      );

      // Border-terminal chrome: every verified-kind terminal (tunnels,
      // select tunnels, both shift registers, the selector) must render
      // BYTE-IDENTICAL to LabVIEW's reference at its decoded rect —
      // borders, fills, glyphs, and wire colours all at once.
      final refPx = (await reference.image.toByteData())!.buffer.asUint8List();
      final chromeCounts = <int, int>{};
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
          for (var y = attach.top; y < attach.bottom; y++) {
            for (var x = attach.left; x < attach.right; x++) {
              final ri =
                  ((y - raster.content.top).toInt() * raster.image.width +
                      (x - raster.content.left).toInt()) *
                  4;
              final fi =
                  ((y - raster.content.top + reg.dy).toInt() *
                          reference.image.width +
                      (x - raster.content.left + reg.dx).toInt()) *
                  4;
              if (rasterPx[ri] != refPx[fi] ||
                  rasterPx[ri + 1] != refPx[fi + 1] ||
                  rasterPx[ri + 2] != refPx[fi + 2]) {
                mismatched++;
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
        }
      }
      // ignore: avoid_print
      print(
        'chrome byte-verified vs reference: '
        '${chromeCounts.entries.map((e) => '0x${e.key.toRadixString(16)} x${e.value}').join(', ')}',
      );
      expect(chromeCounts.keys.toSet(), {0x22, 0x2d, 0x27, 0x28, 0x2e});

      // Routed-wire pixels: wires with a PROVEN absolute polyline
      // ([ViWire.routePoints]) must reproduce the reference BYTE-FOR-BYTE
      // along the stroke band (route row ±2), away from the endpoints
      // (chrome and the stylised structure bands, which are not
      // byte-faithful) and outside every leaf object's box (icons and
      // terminals legitimately overdraw the runs). The three probes cover the three
      // stroke laws: sig 403 (scalar boolean — dotted checkerboard), sig
      // 1831 (scalar int — solid 1 px), sig 921 (dotted with a bend, both
      // orientations); 403 and 921 also cross sig 917's 2 px vertical, so
      // the crossing gaps are inside the compared band.
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

      // Crossing rule at a concrete crossing: sig 403 (earlier-serialized,
      // dotted green, row 297) × sig 917 (later, 2 px blue vertical whose
      // route column is 503 — ink columns 502-503). The LATER wire breaks
      // with a 1 px gap either side of the earlier wire's row; the dot on
      // (503,297) survives ((x+y) even). Byte-identical to the reference
      // over the crossing neighbourhood, and the gap shape is asserted
      // explicitly so a regression names itself.
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
      // The later 2 px vertical runs solid above and below ...
      expect(ours(502, 295), blue);
      expect(ours(503, 295), blue);
      expect(ours(502, 299), blue);
      expect(ours(503, 299), blue);
      // ... breaks for one row either side of the survivor ...
      expect(ours(502, 296), white);
      expect(ours(503, 296), white);
      expect(ours(502, 298), white);
      expect(ours(503, 298), white);
      // ... and the earlier wire's checkerboard dot survives on the row.
      expect(ours(503, 297), green);
      expect(ours(502, 297), white);
    });
  });
}
