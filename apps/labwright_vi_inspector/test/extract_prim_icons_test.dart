import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Generates the app's primitive-icon assets from LabVIEW's own renders:
/// every snippet is registered against its embedded reference, each primitive
/// node's box is cut from the REFERENCE pixels, the cleanest sample per
/// primResID is trimmed to its ink and its exterior background made
/// transparent, and the result lands in `assets/prim_icons/prim<id>.png` for
/// the node painter to stamp (and for hand-editing — the PNGs carry alpha).
///
/// Generation is opt-in (it rewrites the checked-in assets):
/// `flutter test test/extract_prim_icons_test.dart --dart-define=EXTRACT_PRIM_ICONS=1`
void main() {
  const enabled = String.fromEnvironment('EXTRACT_PRIM_ICONS');
  testWidgets(
    'verified icons reproduce pixel-for-pixel; EXTRACT_PRIM_ICONS=1 regenerates the rest',
    (tester) async {
      await loadRealTextFont();
      final pngs = snippetCorpusPngs();
      if (pngs.isEmpty) return;
      final appDir = repoDir('apps/labwright_vi_inspector')!.path;
      final outDir = Directory('$appDir/assets/prim_icons')
        ..createSync(recursive: true);
      // Asset key -> candidate crops. Keys: 'prim<id>' for primResID-bearing
      // nodes, 'class<code>' for the single-op primitive classes that carry no
      // primResID (their class IS the identity — 0x44 etc.).
      const primClasses = {
        0x3a,
        0x34,
        0x3e,
        0x44,
        0x6c,
        0x93,
        0x172,
        0x185,
        0x370,
      };
      final samples =
          <
            String,
            List<
              ({Uint8List rgba, int w, int h, String source, double quality})
            >
          >{};
      final skippedLowQuality = <String>[];
      final observedKeys = <String>{};
      await tester.runAsync(() async {
        for (final f in pngs) {
          final vi = extractSnippetVi(f.readAsBytesSync());
          if (vi == null) continue;
          final model = buildViModel(vi);
          final bd = bestBlockDiagram(model);
          if (bd == null) continue;
          final raster = await rasteriseBlockDiagram(bd, scale: 1.0, margin: 2);
          if (raster == null) continue;
          final reference = await decodeReferenceImage(f.readAsBytesSync());
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(bd, raster),
          );
          if (!result.registered) continue;
          final reg = result.registration;
          // Only well-registered snippets contribute: a global registration a
          // few pixels off lands every crop on the wrong pixels.
          final placement = comparePlacement(
            diagram: bd,
            raster: raster,
            registration: reg,
            referenceRgba: result.referenceRgba,
            width: reference.image.width,
            height: reference.image.height,
          );
          final lowQuality =
              placement.objects > 0 && placement.excessSupport < 0.7;
          if (lowQuality) skippedLowQuality.add(f.uri.pathSegments.last);
          final quality = placement.objects == 0
              ? 0.0
              : placement.excessSupport;
          final refW = reference.image.width, refH = reference.image.height;
          final name = f.uri.pathSegments.last.replaceAll('.png', '');
          for (final o in bd.objects) {
            final key = o.primResId != null
                ? 'prim${o.primResId}'
                : (primClasses.contains(o.kind) ? 'class${o.kind}' : null);
            final b = o.absBounds;
            if (key == null || b == null || b.width <= 0 || b.height <= 0) {
              continue;
            }
            // Every observed identity stays visible even when no snippet can
            // contribute pixels for it.
            observedKeys.add(key);
            if (lowQuality) continue;
            // A node inside a disable structure renders greyed — its washed
            // colours would poison the palette.
            var anc = bd.byId[o.parentOid ?? -1];
            var hops = 0;
            var disabled = false;
            while (anc != null && hops++ < 12) {
              if (anc.kind == 0xcd) {
                disabled = true;
                break;
              }
              anc = bd.byId[anc.parentOid ?? -1];
            }
            if (disabled) continue;
            if ((samples[key]?.length ?? 0) >= 8) continue;
            const pad = 5;
            final left =
                ((b.left - raster.content.left) * raster.scale * reg.scale +
                        reg.dx)
                    .round() -
                pad;
            final top =
                ((b.top - raster.content.top) * raster.scale * reg.scale +
                        reg.dy)
                    .round() -
                pad;
            final w = (b.width * raster.scale * reg.scale).round() + 2 * pad;
            final h = (b.height * raster.scale * reg.scale).round() + 2 * pad;
            if (left < 0 || top < 0 || left + w > refW || top + h > refH)
              continue;
            final crop = Uint8List(w * h * 4);
            for (var y = 0; y < h; y++) {
              final src = ((top + y) * refW + left) * 4;
              crop.setRange(
                y * w * 4,
                (y + 1) * w * 4,
                result.referenceRgba,
                src,
              );
            }
            (samples[key] ??= []).add((
              rgba: crop,
              w: w,
              h: h,
              source: name,
              quality: quality,
            ));
          }
        }
      });

      bool inky(Uint8List rgba, int w, int x, int y) {
        final i = (y * w + x) * 4;
        return rgba[i] < 240 || rgba[i + 1] < 240 || rgba[i + 2] < 240;
      }

      // Exterior background -> transparent: flood near-white from the image
      // border inward (interior whites — an icon's fill — stay opaque).
      void floodTransparent(img.Image icon) {
        bool nearWhite(img.Pixel p) => p.r >= 240 && p.g >= 240 && p.b >= 240;
        final iw = icon.width, ih = icon.height;
        final stack = <(int, int)>[];
        for (var x = 0; x < iw; x++) {
          stack.add((x, 0));
          stack.add((x, ih - 1));
        }
        for (var y = 0; y < ih; y++) {
          stack.add((0, y));
          stack.add((iw - 1, y));
        }
        while (stack.isNotEmpty) {
          final (x, y) = stack.removeLast();
          if (x < 0 || y < 0 || x >= iw || y >= ih) continue;
          final p = icon.getPixel(x, y);
          if (p.a == 0 || !nearWhite(p)) continue;
          icon.setPixelRgba(x, y, 0, 0, 0, 0);
          stack.addAll([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]);
        }
      }

      // Erases wire tails: ink connected to the left/right crop edge through
      // pixels whose vertical ink run stays wire-thin (<= 3 px). The walk
      // stops where the tail meets icon art (outlines run taller), so a wire
      // fused to a gate erases up to the gate and no further.
      void erodeWireTails(Uint8List rgba, int w, int h) {
        int vrun(int x, int y) {
          var t = y, b = y;
          while (t > 0 && inky(rgba, w, x, t - 1)) {
            t--;
          }
          while (b < h - 1 && inky(rgba, w, x, b + 1)) {
            b++;
          }
          return b - t + 1;
        }

        int hrun(int x, int y) {
          var l = x, r = x;
          while (l > 0 && inky(rgba, w, l - 1, y)) {
            l--;
          }
          while (r < w - 1 && inky(rgba, w, r + 1, y)) {
            r++;
          }
          return r - l + 1;
        }

        // Horizontal wires come in at the left/right edges (wire-thin
        // vertically); vertical wires at the top/bottom (wire-thin
        // horizontally).
        final queue = <(int, int, bool)>[];
        for (var y = 0; y < h; y++) {
          for (final x in [0, w - 1]) {
            if (inky(rgba, w, x, y) && vrun(x, y) <= 3) queue.add((x, y, true));
          }
        }
        for (var x = 0; x < w; x++) {
          for (final y in [0, h - 1]) {
            if (inky(rgba, w, x, y) && hrun(x, y) <= 3)
              queue.add((x, y, false));
          }
        }
        while (queue.isNotEmpty) {
          final (x, y, horiz) = queue.removeLast();
          if (x < 0 || y < 0 || x >= w || y >= h) continue;
          if (!inky(rgba, w, x, y)) continue;
          if (horiz ? vrun(x, y) > 3 : hrun(x, y) > 3) continue;
          final i = (y * w + x) * 4;
          rgba[i] = rgba[i + 1] = rgba[i + 2] = 255;
          queue.addAll([
            (x + 1, y, horiz),
            (x - 1, y, horiz),
            (x, y + 1, horiz),
            (x, y - 1, horiz),
            // Dashed wires (boolean) alternate ink and gaps: jump up to 3 px
            // of background along the travel axis so a dash train erases as
            // one tail; the thinness guard still stops at real art.
            if (horiz) ...[
              (x + 2, y, horiz),
              (x + 3, y, horiz),
              (x - 2, y, horiz),
              (x - 3, y, horiz),
              (x + 2, y + 1, horiz),
              (x + 2, y - 1, horiz),
              (x - 2, y + 1, horiz),
              (x - 2, y - 1, horiz),
            ] else ...[
              (x, y + 2, horiz),
              (x, y + 3, horiz),
              (x, y - 2, horiz),
              (x, y - 3, horiz),
            ],
          ]);
        }
      }

      final manifest = StringBuffer(
        '# Primitive icon assets\n\n'
        'Generated from LabVIEW\'s own renders in the snippet corpus (see\n'
        'test/extract_prim_icons_test.dart): per identity, the samples are\n'
        'aligned and consensus-voted per pixel (attached wires and neighbour\n'
        'ink vanish where the samples disagree), edge-touching wire stubs are\n'
        'erased, the result is trimmed to its ink and the exterior background\n'
        'made transparent. Hand-edits welcome — the painter stamps these at\n'
        'natural size.\n\n'
        '| asset | op | size | sources |\n|---|---|---|---|\n',
      );
      var written = 0;
      // A VERIFIED icon is the maintainer's ground truth: the generator never
      // re-extracts or deletes it, whatever the pipeline thinks of its
      // sources.
      final catalogNow = File(
        '$appDir/lib/src/prim_icon_catalog.dart',
      ).readAsStringSync();
      final verifiedKeys = {
        for (final m in RegExp(
          r"'([a-z0-9]+)': PrimIconStatus\.verified,",
        ).allMatches(catalogNow))
          m.group(1)!,
      };
      // Hand-finished verified art: kept authoritative, never byte-compared
      // (the pipeline cannot reproduce hand cleanup), never rewritten.
      final handKeys = {
        for (final m in RegExp(
          r"'([a-z0-9]+)': PrimIconStatus\.verifiedHand,",
        ).allMatches(catalogNow))
          m.group(1)!,
      };
      // A refactor of the catalog file that broke these regexes would
      // silently disable the whole contract — the parse must see the map.
      expect(
        RegExp(
          r"'([a-z0-9]+)': PrimIconStatus\.",
        ).allMatches(catalogNow).length,
        greaterThan(50),
        reason: 'kPrimIconStatus parse came back (near-)empty',
      );
      final pending = <String, ({img.Image icon, String sources})>{};
      // Extraction NEVER silently drops an identity: failures land here and in
      // the manifest with their reason.
      final failed = <String, String>{};
      final keys = samples.keys.toList()..sort();
      for (final key in keys) {
        final all = samples[key]!;
        // Consensus base: the modal sample dimensions (identities render at a
        // fixed size; a divergent box is a mis-registered crop).
        final dims = <String, int>{};
        for (final s in all) {
          dims['${s.w}x${s.h}'] = (dims['${s.w}x${s.h}'] ?? 0) + 1;
        }
        final modal = (dims.entries.toList()..sort((a, b) => b.value - a.value))
            .first
            .key;
        final group = all.where((s) => '${s.w}x${s.h}' == modal).toList()
          ..sort((a, b) => b.quality.compareTo(a.quality));
        final w0 = group.first.w, h0 = group.first.h;

        // RECT-BORDERED fast path (the border gate): when a reference crop
        // shows a COMPLETE dark ring exactly at the node box perimeter, the
        // icon is that box rect VERBATIM — the reference's own pixels beat
        // any cleaning, wires attach outside the ring (LabVIEW draws the
        // icon over them), and a candidate whose ring is broken or whose
        // rect disagrees with the others is dirt by definition. Ring-exact
        // rects are grouped byte-identically: prim keys ship the modal
        // group (their art is globally unique; a minority rect is
        // overdrawn); a CLASS key with two or more disagreeing rect groups
        // carries multiple arts under one key (the class is not an
        // identity) and FAILS rather than shipping any of them.
        const boxPad = 5;
        final bw = w0 - 2 * boxPad, bh = h0 - 2 * boxPad;
        bool ringComplete(Uint8List rgba) {
          if (bw < 8 || bh < 8) return false;
          for (var x = boxPad; x < boxPad + bw; x++) {
            if (!inky(rgba, w0, x, boxPad) ||
                !inky(rgba, w0, x, boxPad + bh - 1)) {
              return false;
            }
          }
          for (var y = boxPad; y < boxPad + bh; y++) {
            if (!inky(rgba, w0, boxPad, y) ||
                !inky(rgba, w0, boxPad + bw - 1, y)) {
              return false;
            }
          }
          return true;
        }

        Uint8List boxRectOf(Uint8List rgba) {
          final out = Uint8List(bw * bh * 4);
          for (var y = 0; y < bh; y++) {
            final src = ((boxPad + y) * w0 + boxPad) * 4;
            out.setRange(y * bw * 4, (y + 1) * bw * 4, rgba, src);
          }
          for (var i = 3; i < out.length; i += 4) {
            out[i] = 255;
          }
          return out;
        }

        final ringed = [
          for (final s in group)
            if (ringComplete(s.rgba))
              (rect: boxRectOf(s.rgba), source: s.source),
        ];
        if (ringed.isNotEmpty) {
          final rectGroups =
              <String, ({Uint8List rect, int count, Set<String> sources})>{};
          for (final c in ringed) {
            final sig = String.fromCharCodes(c.rect);
            final prev = rectGroups[sig];
            rectGroups[sig] = (
              rect: c.rect,
              count: (prev?.count ?? 0) + 1,
              sources: {...?prev?.sources, c.source},
            );
          }
          // The fg-class captures AA their renders (non-web-safe blends);
          // a rect group whose pixels are dominantly web-safe outranks a
          // larger blended group — same dominant-palette rule the terminal
          // art pipeline uses.
          double webSafe(Uint8List rect) {
            var safe = 0;
            for (var i = 0; i < rect.length; i += 4) {
              if (rect[i] % 0x33 == 0 &&
                  rect[i + 1] % 0x33 == 0 &&
                  rect[i + 2] % 0x33 == 0) {
                safe++;
              }
            }
            return safe / (rect.length ~/ 4);
          }

          final ranked = rectGroups.values.toList()
            ..sort((a, b) {
              final ws =
                  (webSafe(b.rect) >= 0.9 ? 1 : 0) -
                  (webSafe(a.rect) >= 0.9 ? 1 : 0);
              return ws != 0 ? ws : b.count.compareTo(a.count);
            });
          if (key.startsWith('class') && ranked.length > 1) {
            failed[key] =
                'class key carries ${ranked.length} distinct border-exact '
                'arts (${ranked.map((g) => '${g.count}x from ${g.sources.join('+')}').join(' | ')}) '
                '— a per-node identity is needed, no single asset can be right';
            continue;
          }
          final win = ranked.first;
          final icon = img.Image(width: bw, height: bh, numChannels: 4);
          for (var y = 0; y < bh; y++) {
            for (var x = 0; x < bw; x++) {
              final i = (y * bw + x) * 4;
              icon.setPixelRgba(
                x,
                y,
                win.rect[i],
                win.rect[i + 1],
                win.rect[i + 2],
                255,
              );
            }
          }
          pending[key] = (
            icon: icon,
            sources:
                'border-exact rect (${win.count}/${ringed.length} ring '
                'samples agree byte-for-byte): ${win.sources.join(', ')}',
          );
          continue;
        }

        for (final smp in all) {
          erodeWireTails(smp.rgba, smp.w, smp.h);
        }

        // Align candidate [b] onto anchor [a]; returns (dx, dy, agreement)
        // where agreement is the matched fraction of the ink union. Two
        // independently CORRECT crops of the same icon agree; a crop that
        // landed on a label or a wire (a displaced model box) agrees with
        // nothing — so the seed is the best-agreeing pair, never a lone
        // anchor that might itself be junk.
        (int, int, double) alignOnto(
          ({Uint8List rgba, int w, int h, String source, double quality}) a,
          ({Uint8List rgba, int w, int h, String source, double quality}) b,
        ) {
          var bestD = 1 << 62, bx = 0, by = 0;
          for (var dy = -5; dy <= 5; dy++) {
            for (var dx = -5; dx <= 5; dx++) {
              var d = 0;
              for (var y = 0; y < h0; y += 2) {
                for (var x = 0; x < w0; x += 2) {
                  final sx = x + dx, sy = y + dy;
                  if (sx < 0 || sy < 0 || sx >= b.w || sy >= b.h) {
                    d += 128;
                    continue;
                  }
                  final i = (y * w0 + x) * 4, j = (sy * b.w + sx) * 4;
                  d +=
                      (a.rgba[i] - b.rgba[j]).abs() +
                      (a.rgba[i + 1] - b.rgba[j + 1]).abs() +
                      (a.rgba[i + 2] - b.rgba[j + 2]).abs();
                }
              }
              if (d < bestD) {
                bestD = d;
                bx = dx;
                by = dy;
              }
            }
          }
          var match = 0, union = 0;
          for (var y = 0; y < h0; y++) {
            for (var x = 0; x < w0; x++) {
              final sx = x + bx, sy = y + by;
              final aInk = inky(a.rgba, w0, x, y);
              final bInk =
                  sx >= 0 &&
                  sy >= 0 &&
                  sx < b.w &&
                  sy < b.h &&
                  inky(b.rgba, b.w, sx, sy);
              if (!aInk && !bInk) continue;
              union++;
              if (aInk && bInk) match++;
            }
          }
          return (bx, by, union == 0 ? 0 : match / union);
        }

        // Seed: the pair with the highest mutual agreement (quality-ordered
        // tiebreak); singletons fall through to the centred-sample fallback.
        var base = group.first;
        var seeded = false;
        if (group.length >= 2) {
          var bestAgree = 0.0;
          for (var i = 0; i < group.length; i++) {
            for (var j = i + 1; j < group.length; j++) {
              final (_, _, agree) = alignOnto(group[i], group[j]);
              if (agree > bestAgree) {
                bestAgree = agree;
                base = group[i];
              }
            }
          }
          seeded = bestAgree >= 0.8;
        }
        final aligned = <({Uint8List rgba, int w, int h, int dx, int dy})>[];
        if (seeded) {
          for (final s in group) {
            final (dx, dy, agree) = alignOnto(base, s);
            if (agree < 0.8) continue;
            aligned.add((rgba: s.rgba, w: s.w, h: s.h, dx: dx, dy: dy));
          }
        }
        final consensus = Uint8List(w0 * h0 * 4);
        for (var y = 0; y < h0; y++) {
          for (var x = 0; x < w0; x++) {
            final votes = <int, int>{};
            for (final a in aligned) {
              final sx = x + a.dx, sy = y + a.dy;
              if (sx < 0 || sy < 0 || sx >= a.w || sy >= a.h) continue;
              final j = (sy * a.w + sx) * 4;
              final q =
                  ((a.rgba[j] >> 4) << 8) |
                  ((a.rgba[j + 1] >> 4) << 4) |
                  (a.rgba[j + 2] >> 4);
              votes[q] = (votes[q] ?? 0) + 1;
            }
            final i = (y * w0 + x) * 4;
            if (votes.isEmpty) {
              consensus[i] = consensus[i + 1] = consensus[i + 2] = 255;
              consensus[i + 3] = 255;
              continue;
            }
            final top =
                (votes.entries.toList()..sort((a, b) => b.value - a.value))
                    .first;
            if (aligned.length >= 3 && top.value * 2 < aligned.length) {
              // No majority: samples disagree here (a wire, a neighbour) —
              // background.
              consensus[i] = consensus[i + 1] = consensus[i + 2] = 255;
              consensus[i + 3] = 255;
              continue;
            }
            // Take the base's true colour when it matches the winning bucket,
            // else the first agreeing sample's (avoids quantisation banding).
            var taken = false;
            for (final a in aligned) {
              final sx = x + a.dx, sy = y + a.dy;
              if (sx < 0 || sy < 0 || sx >= a.w || sy >= a.h) continue;
              final j = (sy * a.w + sx) * 4;
              final q =
                  ((a.rgba[j] >> 4) << 8) |
                  ((a.rgba[j + 1] >> 4) << 4) |
                  (a.rgba[j + 2] >> 4);
              if (q == top.key) {
                consensus[i] = a.rgba[j];
                consensus[i + 1] = a.rgba[j + 1];
                consensus[i + 2] = a.rgba[j + 2];
                consensus[i + 3] = 255;
                taken = true;
                break;
              }
            }
            if (!taken) {
              consensus[i] = consensus[i + 1] = consensus[i + 2] = 255;
              consensus[i + 3] = 255;
            }
          }
        }
        // Wire stubs: coloured components touching the left/right edge whose
        // bounding box is at most 4 px tall are wire runs, not icon art.
        final visited = List<bool>.filled(w0 * h0, false);
        for (final startX in [0, w0 - 1]) {
          for (var startY = 0; startY < h0; startY++) {
            if (visited[startY * w0 + startX] ||
                !inky(consensus, w0, startX, startY)) {
              continue;
            }
            final comp = <int>[];
            final queue = <(int, int)>[(startX, startY)];
            var minY = startY, maxY = startY;
            while (queue.isNotEmpty) {
              final (x, y) = queue.removeLast();
              if (x < 0 || y < 0 || x >= w0 || y >= h0) continue;
              final idx = y * w0 + x;
              if (visited[idx] || !inky(consensus, w0, x, y)) continue;
              visited[idx] = true;
              comp.add(idx);
              if (y < minY) minY = y;
              if (y > maxY) maxY = y;
              queue.addAll([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]);
            }
            if (comp.isNotEmpty && maxY - minY < 4) {
              for (final idx in comp) {
                consensus[idx * 4] = consensus[idx * 4 + 1] =
                    consensus[idx * 4 + 2] = 255;
              }
            }
          }
        }
        // Keep only the main ink cluster: the largest connected component
        // plus components whose 3 px-dilated bounding box touches the kept
        // cluster (multi-part glyphs chain in; dashed-wire fragments and far
        // junk in the padded crop drop out).
        void keepMainCluster(Uint8List rgba) {
          final compOf = List<int>.filled(w0 * h0, -1);
          final comps = <({List<int> px, int l, int t, int r, int b})>[];
          for (var y = 0; y < h0; y++) {
            for (var x = 0; x < w0; x++) {
              if (compOf[y * w0 + x] != -1 || !inky(rgba, w0, x, y)) continue;
              final id = comps.length;
              final pixels = <int>[];
              int cl = x, ct = y, cr = x, cb = y;
              final queue = <(int, int)>[(x, y)];
              while (queue.isNotEmpty) {
                final (px, py) = queue.removeLast();
                if (px < 0 || py < 0 || px >= w0 || py >= h0) continue;
                final idx = py * w0 + px;
                if (compOf[idx] != -1 || !inky(rgba, w0, px, py)) continue;
                compOf[idx] = id;
                pixels.add(idx);
                if (px < cl) cl = px;
                if (px > cr) cr = px;
                if (py < ct) ct = py;
                if (py > cb) cb = py;
                queue.addAll([
                  (px + 1, py),
                  (px - 1, py),
                  (px, py + 1),
                  (px, py - 1),
                  (px + 1, py + 1),
                  (px - 1, py - 1),
                  (px + 1, py - 1),
                  (px - 1, py + 1),
                ]);
              }
              comps.add((px: pixels, l: cl, t: ct, r: cr, b: cb));
            }
          }
          if (comps.length < 2) return;
          var main = 0;
          for (var i = 1; i < comps.length; i++) {
            if (comps[i].px.length > comps[main].px.length) main = i;
          }
          final kept = <int>{main};
          var kl = comps[main].l,
              kt = comps[main].t,
              kr = comps[main].r,
              kb = comps[main].b;
          var grew = true;
          while (grew) {
            grew = false;
            for (var i = 0; i < comps.length; i++) {
              if (kept.contains(i)) continue;
              final c = comps[i];
              // Inside the cluster: always keep (glyph dots, inner marks).
              final inside =
                  c.l >= kl - 1 &&
                  c.r <= kr + 1 &&
                  c.t >= kt - 1 &&
                  c.b <= kb + 1;
              // Adjacent AND not wire-like: a dash chain (2-3 px tall) never
              // joins, so dashed wires cannot ladder into the cluster.
              final adjacent =
                  c.l - 2 <= kr &&
                  c.r + 2 >= kl &&
                  c.t - 2 <= kb &&
                  c.b + 2 >= kt;
              final wireLike = (c.b - c.t + 1) <= 3 || (c.r - c.l + 1) <= 1;
              if (inside || (adjacent && !wireLike)) {
                kept.add(i);
                if (c.l < kl) kl = c.l;
                if (c.t < kt) kt = c.t;
                if (c.r > kr) kr = c.r;
                if (c.b > kb) kb = c.b;
                grew = true;
              }
            }
          }
          for (var i = 0; i < comps.length; i++) {
            if (kept.contains(i)) continue;
            for (final idx in comps[i].px) {
              rgba[idx * 4] = rgba[idx * 4 + 1] = rgba[idx * 4 + 2] = 255;
            }
          }
        }

        keepMainCluster(consensus);
        // Trim to ink; a consensus that erased everything (heavily disagreeing
        // samples) falls back to the cleanest single sample so every identity
        // keeps an icon.
        int l = w0, t = h0, r = -1, btm = -1;
        void measure(Uint8List rgba) {
          l = w0;
          t = h0;
          r = -1;
          btm = -1;
          for (var y = 0; y < h0; y++) {
            for (var x = 0; x < w0; x++) {
              if (!inky(rgba, w0, x, y)) continue;
              if (x < l) l = x;
              if (x > r) r = x;
              if (y < t) t = y;
              if (y > btm) btm = y;
            }
          }
        }

        // Fallback selector: per sample, clean it the same way (erosion
        // already ran; cluster it), then pick the sample whose surviving ink
        // is largest, covers the crop centre, AND fits the node box (+6 px
        // growable slack) — a sliver, an off-centre fragment, or a label
        // crop from a displaced model box never wins.
        Uint8List? centredSingle() {
          var bestInk = 0;
          Uint8List? single;
          for (final s in group) {
            final copy = Uint8List.fromList(s.rgba);
            keepMainCluster(copy);
            measure(copy);
            if (r < 0) continue;
            // A sample whose surviving ink reaches the crop edge is still
            // fused to a wire — never a salvage candidate.
            if (l == 0 || t == 0 || r == w0 - 1 || btm == h0 - 1) continue;
            final cx = w0 ~/ 2, cy = h0 ~/ 2;
            if (l > cx || r < cx || t > cy || btm < cy) continue;
            if (r - l + 1 > w0 - 4 || btm - t + 1 > h0 - 4) continue;
            var ink = 0;
            for (var y = t; y <= btm; y++) {
              for (var x = l; x <= r; x++) {
                if (inky(copy, w0, x, y)) ink++;
              }
            }
            if (ink > bestInk) {
              bestInk = ink;
              single = copy;
            }
          }
          return bestInk < 60 ? null : single;
        }

        var method = seeded
            ? 'pair-seeded consensus'
            : 'single-sample fallback';
        measure(consensus);
        if (r < 0 || (r - l + 1) * (btm - t + 1) < 24) {
          final single = centredSingle();
          if (single == null) {
            failed[key] =
                'no agreeing consensus and no centred sample survived cleaning '
                '(${group.length} samples)';
            continue;
          }
          method = 'single-sample fallback';
          consensus.setAll(0, single);
          measure(consensus);
        }
        if (r < 0) {
          failed[key] = 'no ink after cleaning (${group.length} samples)';
          continue;
        }
        // Surviving consensus ink on the crop edge means a wire fused past
        // every cleaning stage (a real icon ends >= pad short of the edge):
        // fall back to the cleanest single sample WITHOUT edge ink; only
        // when none exists does the key fail — an absent icon beats
        // shipping the wire.
        if (l == 0 || t == 0 || r == w0 - 1 || btm == h0 - 1) {
          final single = centredSingle();
          if (single == null) {
            failed[key] =
                'cleaned ink still reaches the crop edge (wire fusion; '
                '${group.length} samples)';
            continue;
          }
          method = 'single-sample fallback after edge fusion';
          consensus.setAll(0, single);
          measure(consensus);
        }
        final w = r - l + 1, h = btm - t + 1;
        final icon = img.Image(width: w, height: h, numChannels: 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = ((t + y) * w0 + l + x) * 4;
            icon.setPixelRgba(
              x,
              y,
              consensus[i],
              consensus[i + 1],
              consensus[i + 2],
              255,
            );
          }
        }
        floodTransparent(icon);
        // Physical prior: an icon cannot exceed the node box that draws it
        // (+6 px for growable-node overflow). A crop that agreed on a LABEL
        // (near-duplicate VIs share the same displaced model box, so their
        // identical wrong crops agree perfectly) fails this and is recorded,
        // never shipped.
        final maxW = w0 - 2 * 5 + 6, maxH = h0 - 2 * 5 + 6;
        var finalIcon = icon;
        if (finalIcon.width > maxW || finalIcon.height > maxH) {
          // The agreeing configuration was junk (near-duplicate VIs share the
          // same displaced model box, so identical wrong crops agree): retry
          // with the strictest single-sample selection before failing.
          final single = centredSingle();
          img.Image? rebuilt;
          if (single != null) {
            measure(single);
            if (r >= 0 && r - l + 1 <= maxW && btm - t + 1 <= maxH) {
              rebuilt = img.Image(
                width: r - l + 1,
                height: btm - t + 1,
                numChannels: 4,
              );
              for (var y = 0; y < rebuilt.height; y++) {
                for (var x = 0; x < rebuilt.width; x++) {
                  final i = ((t + y) * w0 + l + x) * 4;
                  rebuilt.setPixelRgba(
                    x,
                    y,
                    single[i],
                    single[i + 1],
                    single[i + 2],
                    255,
                  );
                }
              }
              floodTransparent(rebuilt);
              method = 'single-sample retry after oversized consensus';
            }
          }
          if (rebuilt == null) {
            failed[key] =
                'extracted ink ${finalIcon.width}x${finalIcon.height} exceeds '
                'the node box (${w0 - 10}x${h0 - 10}) — displaced model bounds '
                'suspected (sources: ${group.map((s) => s.source).toSet().join(', ')})';
            continue;
          }
          finalIcon = rebuilt;
        }
        pending[key] = (
          icon: finalIcon,
          sources:
              '${group.map((s) => s.source).toSet().join(', ')} — $method '
              '(${aligned.length}/${group.length} agreeing)',
        );
      }

      // Master palette: the exact colours that dominate the harvested art —
      // per 4-bit RGB bucket, the modal exact colour, kept when the bucket
      // covers at least 0.2% of all opaque pixels; black and white always.
      // Every pixel snaps to its nearest palette entry: LabVIEW's icon art is
      // flat-colour, so the snap erases the reference render's anti-aliased
      // fringe and gives the renderer a closed colour set to remap (an
      // "inactive" palette later swaps entry-for-entry).
      final bucketCounts = <int, int>{};
      final bucketModal = <int, Map<int, int>>{};
      var opaque = 0;
      for (final e in pending.values) {
        for (final px in e.icon) {
          if (px.a == 0) continue;
          opaque++;
          final rgb = (px.r.toInt() << 16) | (px.g.toInt() << 8) | px.b.toInt();
          final bucket =
              ((px.r.toInt() >> 4) << 8) |
              ((px.g.toInt() >> 4) << 4) |
              (px.b.toInt() >> 4);
          bucketCounts[bucket] = (bucketCounts[bucket] ?? 0) + 1;
          final modal = bucketModal[bucket] ??= {};
          modal[rgb] = (modal[rgb] ?? 0) + 1;
        }
      }
      final palette = <int>{0x000000, 0xffffff};
      for (final e in bucketCounts.entries) {
        if (e.value * 500 < opaque) continue;
        palette.add(
          (bucketModal[e.key]!.entries.toList()
                ..sort((a, b) => b.value - a.value))
              .first
              .key,
        );
      }
      final paletteList = palette.toList()..sort();
      int snap(int r, int g, int b) {
        var best = 0, bd = 1 << 30;
        for (final c in paletteList) {
          final dr = r - ((c >> 16) & 0xff),
              dg = g - ((c >> 8) & 0xff),
              db = b - (c & 0xff);
          final d = dr * dr + dg * dg + db * db;
          if (d < bd) {
            bd = d;
            best = c;
          }
        }
        return best;
      }

      manifest.writeln(
        '\nPalette (${paletteList.length} colours — every icon pixel is one of '
        'these): ${paletteList.map((c) => '#${c.toRadixString(16).padLeft(6, '0')}').join(' ')}\n',
      );
      // Palette snap happens BEFORE the reproducibility check so verified
      // comparisons cover the exact bytes that would ship.
      for (final key in pending.keys.toList()..sort()) {
        final e = pending[key]!;
        for (final px in e.icon) {
          if (px.a == 0) continue;
          final c = snap(px.r.toInt(), px.g.toInt(), px.b.toInt());
          e.icon.setPixelRgba(
            px.x,
            px.y,
            (c >> 16) & 0xff,
            (c >> 8) & 0xff,
            c & 0xff,
            255,
          );
        }
      }

      // REPRODUCIBILITY CONTRACT: a VERIFIED icon is pinned. The pipeline must
      // either reproduce its committed pixels exactly or produce nothing (art
      // the maintainer verified by hand ahead of the pipeline — kept and
      // reported). A DIFFERENT extraction for a verified key fails the suite:
      // algorithm changes never silently alter verified assets.
      final reproErrors = <String>[];
      for (final key in verifiedKeys) {
        final files = Directory(outDir.path)
            .listSync()
            .whereType<File>()
            .where(
              (f) => RegExp('/$key(?:_[a-z0-9-]+)?\\.png\$').hasMatch(f.path),
            )
            .toList();
        if (files.isEmpty) {
          reproErrors.add('$key is marked verified but has no committed asset');
          continue;
        }
        final committed = img.decodePng(files.first.readAsBytesSync())!;
        final fresh = pending[key]?.icon;
        if (fresh == null) {
          // A verified key is pipeline-pinned (hand-finished art is
          // verifiedHand instead): the pipeline no longer extracting it at
          // all IS a reproducibility regression.
          reproErrors.add(
            '$key is verified but the pipeline produced no extraction '
            '(${failed[key] ?? 'no extraction output'})',
          );
          continue;
        }
        if (fresh.width != committed.width ||
            fresh.height != committed.height) {
          reproErrors.add(
            '$key: fresh extraction is ${fresh.width}x${fresh.height}, the '
            'committed verified asset is ${committed.width}x${committed.height}',
          );
          continue;
        }
        var diffs = 0;
        for (final px in fresh) {
          final cp = committed.getPixel(px.x, px.y);
          if (px.r != cp.r || px.g != cp.g || px.b != cp.b || px.a != cp.a) {
            diffs++;
          }
        }
        if (diffs > 0) {
          reproErrors.add(
            '$key: $diffs pixels differ from the committed verified asset',
          );
        }
      }
      expect(
        reproErrors,
        isEmpty,
        reason:
            'the extraction algorithm no longer reproduces verified icons:\n'
            '${reproErrors.join('\n')}',
      );
      if (enabled.isEmpty) return; // verify-only: nothing is written

      for (final key in pending.keys.toList()..sort()) {
        final e = pending[key]!;
        if (verifiedKeys.contains(key) || handKeys.contains(key)) {
          // The committed verified asset stays authoritative (byte-identity
          // proven above for pipeline-verified keys; hand-finished art is
          // authoritative by definition); nothing to write.
          manifest.writeln(
            '| $key | (verified — committed asset authoritative) | | ${e.sources} |',
          );
          written++;
          continue;
        }
        final primId = key.startsWith('prim')
            ? int.parse(key.substring(4))
            : null;
        final op = primId == null ? null : PrimOp.fromId(primId);
        final classCode = key.startsWith('class')
            ? int.parse(key.substring(5))
            : null;
        final file = op != null ? '${key}_${op.slug}.png' : '$key.png';
        File('${outDir.path}/$file').writeAsBytesSync(img.encodePng(e.icon));
        final label =
            op?.opName ??
            (classCode != null
                ? 'class 0x${classCode.toRadixString(16)}'
                : '(uncatalogued)');
        manifest.writeln(
          '| $file | $label | ${e.icon.width}x${e.icon.height} | ${e.sources} |',
        );
        written++;
      }
      for (final key in observedKeys) {
        if (!pending.containsKey(key) && !failed.containsKey(key)) {
          failed[key] = 'every sample came from a low-registration snippet';
        }
      }
      if (failed.isNotEmpty) {
        manifest.writeln(
          '\n## Identities without a usable asset (kept visible, never hidden)\n',
        );
        for (final e
            in (failed.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))) {
          manifest.writeln('- ${e.key}: ${e.value}');
        }
      }
      if (skippedLowQuality.isNotEmpty) {
        manifest.writeln(
          '\nSnippets excluded from harvesting (registration below the 0.7 '
          'placement gate): ${skippedLowQuality.toSet().join(', ')}\n',
        );
      }
      // A stale asset for a key that no longer extracts (and is not
      // verified) would stamp silently with no manifest row — remove it. The
      // removal is loud: it lands in the manifest's failure list above.
      for (final f in Directory(outDir.path).listSync().whereType<File>()) {
        final m = RegExp(
          r'((?:prim|class)\d+)(?:_[a-z0-9-]+)?\.png$',
        ).firstMatch(f.path);
        if (m == null) continue;
        final key = m.group(1)!;
        if (!pending.containsKey(key) &&
            !verifiedKeys.contains(key) &&
            !handKeys.contains(key)) {
          f.deleteSync();
        }
      }
      File('${outDir.path}/MANIFEST.md').writeAsStringSync(manifest.toString());

      // Regenerate the review catalog, preserving the maintainer's statuses.
      final catalogFile = File('$appDir/lib/src/prim_icon_catalog.dart');
      final existing = catalogFile.readAsStringSync();
      final oldStatus = {
        for (final m in RegExp(
          r"'([a-z0-9]+)': PrimIconStatus\.(\w+)",
        ).allMatches(existing))
          m.group(1)!: m.group(2)!,
      };
      // Maintainer ground truth NEVER falls out of the catalog: a
      // verified / hand-finished / rejected key keeps its entry even when
      // this sweep observed no sample for it (dropping one once made a
      // later run's handKeys parse miss it and reap its asset).
      final allKeys = {
        ...pending.keys,
        ...failed.keys,
        for (final e in oldStatus.entries)
          if (e.value != 'unverified') e.key,
      }.toList()..sort();
      final entries = StringBuffer(
        'const Map<String, PrimIconStatus> kPrimIconStatus = {\n',
      );
      for (final key in allKeys) {
        entries.writeln(
          "  '$key': PrimIconStatus.${oldStatus[key] ?? 'unverified'},",
        );
      }
      entries.writeln('};');
      final begin = existing.indexOf(
        '// statuses are preserved — edit them freely.)',
      );
      final beginEnd = existing.indexOf('\n', begin) + 1;
      final end = existing.indexOf('// GENERATED-ENTRIES-END');
      catalogFile.writeAsStringSync(
        existing.substring(0, beginEnd) +
            entries.toString() +
            existing.substring(end),
      );
      // ignore: avoid_print
      print('wrote $written icon assets to ${outDir.path}');
    },
  );
}
