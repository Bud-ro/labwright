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
  testWidgets('generate primitive icon assets from snippet references', (
    tester,
  ) async {
    if (enabled.isEmpty) {
      markTestSkipped('pass --dart-define=EXTRACT_PRIM_ICONS=1 to generate');
      return;
    }
    await loadRealTextFont();
    final pngs = snippetCorpusPngs();
    if (pngs.isEmpty) return;
    final appDir = repoDir('apps/labwright_vi_inspector')!.path;
    final outDir = Directory('$appDir/assets/prim_icons')
      ..createSync(recursive: true);
    // Asset key -> candidate crops. Keys: 'prim<id>' for primResID-bearing
    // nodes, 'class<code>' for the single-op primitive classes that carry no
    // primResID (their class IS the identity — 0x44 etc.).
    const primClasses = {0x3a, 0x34, 0x3e, 0x44, 0x6c, 0x93, 0x172};
    final samples =
        <String, List<({Uint8List rgba, int w, int h, String source})>>{};
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
              ((b.top - raster.content.top) * raster.scale * reg.scale + reg.dy)
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
          (samples[key] ??= []).add((rgba: crop, w: w, h: h, source: name));
        }
      }
    });

    bool inky(Uint8List rgba, int w, int x, int y) {
      final i = (y * w + x) * 4;
      return rgba[i] < 240 || rgba[i + 1] < 240 || rgba[i + 2] < 240;
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
          if (inky(rgba, w, x, y) && hrun(x, y) <= 3) queue.add((x, y, false));
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
    final pending = <String, ({img.Image icon, String sources})>{};
    final keys = samples.keys.toList()..sort();
    for (final key in keys) {
      final all = samples[key]!;
      for (final smp in all) {
        erodeWireTails(smp.rgba, smp.w, smp.h);
      }
      // Consensus base: the modal sample dimensions (identities render at a
      // fixed size; a divergent box is a mis-registered crop).
      final dims = <String, int>{};
      for (final s in all) {
        dims['${s.w}x${s.h}'] = (dims['${s.w}x${s.h}'] ?? 0) + 1;
      }
      final modal =
          (dims.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
      final group = all.where((s) => '${s.w}x${s.h}' == modal).toList();
      final base = group.first;
      final w0 = base.w, h0 = base.h;

      int diffAt(
        ({Uint8List rgba, int w, int h, String source}) s,
        int dx,
        int dy,
      ) {
        var d = 0;
        for (var y = 0; y < h0; y++) {
          for (var x = 0; x < w0; x++) {
            final sx = x + dx, sy = y + dy;
            if (sx < 0 || sy < 0 || sx >= s.w || sy >= s.h) {
              d += 128;
              continue;
            }
            final i = (y * w0 + x) * 4, j = (sy * s.w + sx) * 4;
            d +=
                (base.rgba[i] - s.rgba[j]).abs() +
                (base.rgba[i + 1] - s.rgba[j + 1]).abs() +
                (base.rgba[i + 2] - s.rgba[j + 2]).abs();
          }
        }
        return d;
      }

      // Align each sample to the base (small translation search), then vote
      // per pixel: the modal quantised colour wins; without a majority the
      // pixel reads as background.
      final aligned = <({Uint8List rgba, int w, int h, int dx, int dy})>[];
      for (final s in group) {
        var bd = 1 << 62, bx = 0, by = 0;
        for (var dy = -5; dy <= 5; dy++) {
          for (var dx = -5; dx <= 5; dx++) {
            final d = diffAt(s, dx, dy);
            if (d < bd) {
              bd = d;
              bx = dx;
              by = dy;
            }
          }
        }
        aligned.add((rgba: s.rgba, w: s.w, h: s.h, dx: bx, dy: by));
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
              (votes.entries.toList()..sort((a, b) => b.value - a.value)).first;
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

      measure(consensus);
      if (r < 0 || (r - l + 1) * (btm - t + 1) < 24) {
        // Fallback: per sample, clean it the same way (erosion already ran;
        // cluster it), then pick the sample whose surviving ink is largest
        // AND covers the crop centre — a sliver or an off-centre fragment
        // never wins.
        var bestInk = 0;
        Uint8List? single;
        for (final s in group) {
          final copy = Uint8List.fromList(s.rgba);
          keepMainCluster(copy);
          measure(copy);
          if (r < 0) continue;
          final cx = w0 ~/ 2, cy = h0 ~/ 2;
          if (l > cx || r < cx || t > cy || btm < cy) continue;
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
        if (single == null || bestInk < 60) continue;
        consensus.setAll(0, single);
        measure(consensus);
      }
      if (r < 0) continue;
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
      // Exterior background -> transparent: flood near-white from the trimmed
      // border inward (interior whites — an icon's fill — stay opaque).
      bool nearWhite(img.Pixel p) => p.r >= 240 && p.g >= 240 && p.b >= 240;
      final stack = <(int, int)>[];
      for (var x = 0; x < w; x++) {
        stack.add((x, 0));
        stack.add((x, h - 1));
      }
      for (var y = 0; y < h; y++) {
        stack.add((0, y));
        stack.add((w - 1, y));
      }
      while (stack.isNotEmpty) {
        final (x, y) = stack.removeLast();
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        final p = icon.getPixel(x, y);
        if (p.a == 0 || !nearWhite(p)) continue;
        icon.setPixelRgba(x, y, 0, 0, 0, 0);
        stack.addAll([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]);
      }
      pending[key] = (
        icon: icon,
        sources: group.map((s) => s.source).toSet().join(', '),
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
    File('${outDir.path}/MANIFEST.md').writeAsStringSync(manifest.toString());
    // ignore: avoid_print
    print('wrote $written icon assets to ${outDir.path}');
  });
}
