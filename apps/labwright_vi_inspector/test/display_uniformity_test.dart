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
      final refPx = (await reference.image.toByteData())!.buffer.asUint8List();
      // Our raster / LabVIEW's reference at ABSOLUTE diagram pixel (x,y): the
      // raster is content-relative, the reference registered by [reg].
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

      // The U8 conversion's wires now ship a proven [ViWire.routePoints]
      // polyline, so each connects at its DECODED attach point on the node's
      // own border — the floored terminal centre, not the old icon-edge
      // guess. The exit wire (leaving on the node's right) carries the op's
      // catalogued output colour — integer blue, from [PrimOp.output] — and
      // the input (arriving on the left) stays string pink from its typed
      // source terminal. Each is located by its own route's endpoint at the
      // U8 node box and sampled at that decoded connection column on the two
      // rows the 1 px stroke half-covers (integer route row and the row
      // above), and must be BYTE-IDENTICAL to LabVIEW's reference there.
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
          // A two-endpoint route runs endpoint 0 → 1, so endpoint e's own
          // connection is the matching end of the polyline.
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
      // The exit wire is integer blue at its decoded connection, byte-exact
      // against the reference on both covered rows.
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
      // 1 px crispness: nothing but pure wire colour and canvas white may
      // appear in the sampled band — a stroked centreline at integer
      // coordinates half-covers two rows (solid core + half-tones).
      expect(
        rightOf.difference({'0,0,255', '255,255,255'}),
        isEmpty,
        reason: 'exit wire must be a crisp 1px fill, no half-tones',
      );
      // The input wire is string pink at its decoded connection, byte-exact
      // against the reference.
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

      // Border-terminal chrome: every verified-kind terminal (tunnels,
      // select tunnels, both shift registers, the selector) must render
      // BYTE-IDENTICAL to LabVIEW's reference at its decoded rect —
      // borders, fills, glyphs, and wire colours all at once — and hold a
      // CLEAN 2 px surround band: no ink of ours on pixels the reference
      // leaves canvas-white (the modeled structure-terminal pass once
      // double-drew these rects and its anti-aliased ring bled a border of
      // blended pixels just outside the byte-exact chrome).
      // Structure-EDGE corridors are excluded from the band: the reference
      // draws crc8's loop/case borders as a 1 px black line (measured on
      // struct 164's left border — a single (0,0,0) column at x=263, white
      // either side) while our structure band is a stylised anti-aliased
      // stroke reaching ~4 px inside and 1 px outside the frame — a known,
      // separate infidelity (TODO: measure the border render laws corpus-
      // wide and draw them byte-faithfully).
      final structureEdgeRects = [
        for (final o in drawable)
          if (o.category == ViObjectKind.structure) o.absBounds!,
      ];
      // Modeled structure-terminal boxes (the N/i corner pair and friends)
      // are likewise excluded, ±1 px for their stroke: which of them
      // LabVIEW actually shows is a visibility decode still in flight, so a
      // modeled box the reference hides must not fail the chrome band
      // (crc8's loop 164 draws its `i` box beside the (263,499) tunnel;
      // the reference does not).
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
      // Synthesized fallback legs (wires without a proven [ViWire.routePoints]
      // polyline) may cross a terminal's band anywhere — their divergence
      // from LabVIEW's stored routing is a route-decode gap, not chrome
      // bleed (crc8's sig 2588 slices through both of loop 571's shift
      // registers at their bottom-border row) — so a ±3 px corridor around
      // each synthesized leg is skipped too. The corridor replays
      // [bdWireRoute] on the attach-preferred anchors, the same inputs the
      // painter routes from.
      final fallbackSegments = <({bool h, int lo, int hi, int cross})>[];
      for (final w in wires) {
        if (w.routePoints != null) continue;
        final anchors = <HeapRect>[];
        for (var e = 0; e < w.endpointAnchors.length; e++) {
          final attach = e < w.endpointAttachRects.length
              ? w.endpointAttachRects[e]
              : null;
          final a = (attach != null && attach.width > 0 && attach.height > 0)
              ? attach
              : w.endpointAnchors[e];
          if (a != null && (a.width > 0 || a.height > 0)) anchors.add(a);
        }
        if (anchors.length < 2) continue;
        ui.Rect rectOf(HeapRect r) => ui.Rect.fromLTRB(
          r.left.toDouble(),
          r.top.toDouble(),
          r.right.toDouble(),
          r.bottom.toDouble(),
        );
        for (var i = 1; i < anchors.length; i++) {
          final pts = bdWireRoute(rectOf(anchors.first), rectOf(anchors[i]));
          for (var j = 1; j < pts.length; j++) {
            final a = pts[j - 1], b = pts[j];
            final h = a.dy == b.dy;
            fallbackSegments.add((
              h: h,
              lo: (h ? min(a.dx, b.dx) : min(a.dy, b.dy)).floor(),
              hi: (h ? max(a.dx, b.dx) : max(a.dy, b.dy)).floor(),
              cross: (h ? a.dy : a.dx).floor(),
            ));
          }
        }
      }
      bool onFallbackLeg(int x, int y) => fallbackSegments.any((s) {
        final (along, cross) = s.h ? (x, y) : (y, x);
        return along >= s.lo - 3 &&
            along <= s.hi + 3 &&
            (cross - s.cross).abs() <= 3;
      });
      bool onStructureEdge(int x, int y) =>
          structureEdgeRects.any(
            (r) =>
                x >= r.left - 1 &&
                x < r.right + 1 &&
                y >= r.top - 1 &&
                y < r.bottom + 1 &&
                !(x >= r.left + 5 &&
                    x < r.right - 5 &&
                    y >= r.top + 5 &&
                    y < r.bottom - 5),
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
              } else if (!onStructureEdge(x, y) && !onFallbackLeg(x, y)) {
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

      // The numeric constant oid 3033 (I32 `256`, inside the disabled LUT
      // frame): its whole 2 px border perimeter must reproduce the
      // reference byte-for-byte — the (153,153,255) dim of integer blue,
      // i.e. type colour THROUGH the disabled-frame transform, with no
      // inner ring (the reference draws constants with the outer border
      // only). The interior text is our font, not LabVIEW's, so it is
      // asserted by property instead: some ink, all of it achromatic and
      // no darker than the (153,153,153) dim of black.
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
      // The removed inner ring's corner pixels stay canvas-white.
      for (final (x, y) in [
        (constBox.left + 3, constBox.top + 3),
        (constBox.right - 4, constBox.top + 3),
        (constBox.left + 3, constBox.bottom - 4),
        (constBox.right - 4, constBox.bottom - 4),
      ]) {
        expect(oursAt(x, y), white, reason: 'inner-ring pixel ($x,$y)');
      }

      // Fallback-routed wire endpoints at icon-stamped nodes: the router
      // anchors the measured art ink bounds, and a leg leaving an icon at a
      // row off its output tip gains the vertical connector at the first
      // column past the art. Each window byte-compares a whole region —
      // art, wire, stub, and canvas at once:
      // - the XOR gate (oid 260) output: the tip stub at x=381 climbing to
      //   the tunnel row 487;
      // - the oid 1379 → oid 1224 gap: the run at the gate's tip row 280
      //   (it previously took oid 1224's box-centre row 271 and missed the
      //   gate art entirely);
      // - the oid 653 → oid 649 gap at the tip row 310, and oid 831's
      //   terminal entry at row 318 (both previously box-anchored rows).
      for (final (label, x0, x1, y0, y1) in [
        ('xor gate output', 378, 397, 481, 501),
        ('1379-1224 gap', 578, 588, 256, 298),
        ('653-649 gap', 716, 727, 306, 316),
        ('831 terminal entry', 866, 872, 310, 326),
      ]) {
        var compared = 0, mismatched = 0;
        for (var y = y0; y <= y1; y++) {
          for (var x = x0; x <= x1; x++) {
            compared++;
            if (oursAt(x, y) != refAt(x, y)) mismatched++;
          }
        }
        // ignore: avoid_print
        print('$label window: $compared px byte-compared, $mismatched off');
        expect(compared, greaterThan(70), reason: label);
        expect(mismatched, 0, reason: '$label must match the reference');
      }

      // The XOR? caption (oid 221) decodes from the scalar-width 0x022 caption
      // record and renders as text ink above the case structure. LabVIEW's
      // font differs from the test's Roboto, so a glyph byte-match is
      // impossible; the caption is asserted by ink presence in its decoded box
      // and by its ink mass tracking the reference's "XOR?" ink there.
      bool isDark(String rgb) {
        final c = rgb.split(',').map(int.parse).toList();
        return c[0] < 160 && c[1] < 160 && c[2] < 160;
      }

      final xorLabel = bd.byId[221]!;
      expect(xorLabel.label, 'XOR?');
      final xbox = xorLabel.absBounds!;
      var xorInk = 0, xorRefInk = 0;
      for (var y = xbox.top; y < xbox.bottom; y++) {
        for (var x = xbox.left; x < xbox.right; x++) {
          if (isDark(oursAt(x, y))) xorInk++;
          if (isDark(refAt(x, y))) xorRefInk++;
        }
      }
      // ignore: avoid_print
      print('XOR? caption ink: raster=$xorInk ref=$xorRefInk');
      expect(
        xorInk,
        greaterThan(20),
        reason: 'the XOR? caption must render as text ink',
      );
      expect(
        (xorInk - xorRefInk).abs(),
        lessThan(25),
        reason: 'the XOR? ink mass must track the reference caption',
      );

      // Constant feeders (the decoded endpoint constant shells): the
      // loop-count wires resolve their far endpoint to the DRAWN constant box
      // (the "8" and two "256" numeric constants) and route to it, not to the
      // structure edge. Each is a short horizontal span from the constant box
      // to the count terminal; the reference wires it continuously, and so
      // does the render.
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

  // Branching wires with a proven junction tree ([ViWire.routeTree]) draw
  // their decoded absolute geometry: every run as an exact origin-relative
  // polyline (feeding the same stroke and crossing-gap machinery as any leg)
  // plus a filled disc at each junction. Several closed trees ship per
  // snippet, but most sit wholly under node/structure boxes (short branches
  // between adjacent terminals) and expose no pixel to the reference; the
  // ink law applies to the exposed runs and junction dots only. Each of
  // Excel_Read_XLSX (a screenshot target) and Read VI Blocks carries exactly
  // one substantially exposed tree, so the branch-wire verification
  // aggregates across the two. Every EXPOSED run pixel and junction-dot pixel
  // — not covered by a node/structure box — must land on wire ink in
  // LabVIEW's own render (masking node overlaps, ±1 row for the reference's
  // anti-aliasing — the colour-presence law the wire-band checks use, since
  // an anti-aliased reference cannot be byte-matched by the crisp render).
  testWidgets('branch-wire routeTree runs + junction dots land on ref ink', (
    tester,
  ) async {
    final root = repoDir('packages/labwright_rsrc_parse/corpus/vi');
    if (root == null) {
      markTestSkipped('corpus not fetched');
      return;
    }
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
        final refPx = (await reference.image.toByteData())!.buffer
            .asUint8List();
        final rasterPx = (await raster.image.toByteData())!.buffer
            .asUint8List();
        final rw = reference.image.width;
        final aw = raster.image.width, ah = raster.image.height;

        // Node/structure/text mask: any drawable box, inflated to cover chrome
        // borders and icon overhang.
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

        // Ink at content pixel (x,y), ±1 row for the reference's anti-aliased
        // wire edges.
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
          // A shipped tree whose every run sits under a node/structure box
          // exposes no pixel to the reference — its geometry is real but
          // wholly occluded (e.g. a short branch between adjacent terminals),
          // so there is nothing to overlay. Only a wire that EXPOSES run
          // pixels carries the ink law; each exposed pixel must land on
          // reference wire ink and be drawn by the render.
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
          // Junction dots: the filled 5x5 disc (corners clipped) at each
          // junction. Every EXPOSED disc pixel must be inked in BOTH images —
          // this catches the off-run cap pixels that only exist because
          // LabVIEW stamps a dot, not merely because two runs cross. A
          // junction buried under a node exposes nothing and is skipped.
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
      }
    });
    // ignore: avoid_print
    print(
      'branch wires verified: $branchWires ($exposedWires exposed, with '
      '$junctionDots junction dots, $runPixels run px)',
    );
    expect(branchWires, greaterThanOrEqualTo(2));
    expect(junctionDots, greaterThanOrEqualTo(2));
    // Real teeth: at least two branch wires (one per snippet) expose a
    // substantial run that the ink law above byte-verified against LabVIEW.
    expect(exposedWires, greaterThanOrEqualTo(2));
    expect(runPixels, greaterThan(2000));
  });
}
