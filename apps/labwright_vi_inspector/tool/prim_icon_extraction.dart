import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import '../test/bd_wire_mask_test.dart' show kWireInkPalette;
import '../test/util.dart';

const Map<String, List<({String snippet, int oid})>> kTargetedIconSamples = {
  'prim1082': [(snippet: 'MD5', oid: 6017)],
  'prim1170': [(snippet: 'crc16', oid: 820), (snippet: 'crc16', oid: 619)],
  'prim1537': [(snippet: 'Excel_Cell_to_RowCol', oid: 477)],
};

({Uint8List rgba, int w, int h, int dx, int dy})? _cleanNodeBoxCrop(
  Uint8List crop,
  int w,
  int h,
  int pad,
) {
  final boxWidth = w - 2 * pad, boxHeight = h - 2 * pad;
  if (boxWidth < 4 || boxHeight < 4) return null;
  final pixels = Uint8List.fromList(crop);
  for (var i = 0; i < pixels.length; i += 4) {
    final rgb = (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
    if (kWireInkPalette.contains(rgb)) {
      pixels[i] = pixels[i + 1] = pixels[i + 2] = 255;
    }
  }
  final background = List<bool>.filled(w * h, false);
  bool nearWhite(int idx) =>
      pixels[idx * 4] >= 240 &&
      pixels[idx * 4 + 1] >= 240 &&
      pixels[idx * 4 + 2] >= 240;
  final stack = <int>[];
  for (var x = 0; x < w; x++) {
    stack.addAll([x, (h - 1) * w + x]);
  }
  for (var y = 0; y < h; y++) {
    stack.addAll([y * w, y * w + w - 1]);
  }
  while (stack.isNotEmpty) {
    final idx = stack.removeLast();
    if (background[idx] || !nearWhite(idx)) continue;
    background[idx] = true;
    final x = idx % w, y = idx ~/ w;
    if (x > 0) stack.add(idx - 1);
    if (x < w - 1) stack.add(idx + 1);
    if (y > 0) stack.add(idx - w);
    if (y < h - 1) stack.add(idx + w);
  }
  final thirdLeft = pad + boxWidth ~/ 3, thirdRight = pad + (2 * boxWidth) ~/ 3;
  final thirdTop = pad + boxHeight ~/ 3,
      thirdBottom = pad + (2 * boxHeight) ~/ 3;
  final seen = List<bool>.filled(w * h, false);
  for (var start = 0; start < w * h; start++) {
    if (seen[start] || background[start]) continue;
    final component = <int>[start];
    final queue = <int>[start];
    seen[start] = true;
    var left = w, top = h, right = -1, bottom = -1, reachesCentre = false;
    while (queue.isNotEmpty) {
      final idx = queue.removeLast();
      final x = idx % w, y = idx ~/ w;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      if (x >= thirdLeft &&
          x < thirdRight &&
          y >= thirdTop &&
          y < thirdBottom) {
        reachesCentre = true;
      }
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final next = ny * w + nx;
          if (seen[next] || background[next]) continue;
          seen[next] = true;
          component.add(next);
          queue.add(next);
        }
      }
    }
    final insideBox =
        left >= pad &&
        top >= pad &&
        right < pad + boxWidth &&
        bottom < pad + boxHeight;
    if (reachesCentre || insideBox) continue;
    for (final idx in component) {
      background[idx] = true;
    }
  }
  var left = w, top = h, right = -1, bottom = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (background[y * w + x]) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return null;
  final artWidth = right - left + 1, artHeight = bottom - top + 1;
  final art = Uint8List(artWidth * artHeight * 4);
  for (var y = 0; y < artHeight; y++) {
    for (var x = 0; x < artWidth; x++) {
      final idx = (top + y) * w + left + x;
      final dst = (y * artWidth + x) * 4;
      art[dst] = pixels[idx * 4];
      art[dst + 1] = pixels[idx * 4 + 1];
      art[dst + 2] = pixels[idx * 4 + 2];
      art[dst + 3] = background[idx] ? 0 : 255;
    }
  }
  return (rgba: art, w: artWidth, h: artHeight, dx: left - pad, dy: top - pad);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class PrimIconExtraction {
  const PrimIconExtraction({
    required this.appDir,
    required this.assetDir,
    required this.pending,
    required this.failed,
    required this.observedKeys,
    required this.skippedLowQuality,
    required this.palette,
    required this.verifiedKeys,
    required this.handKeys,
    required this.renamed,
  });

  final String appDir;
  final Directory assetDir;

  final Map<String, ({img.Image icon, String sources})> pending;

  final Map<String, String> failed;

  final Set<String> observedKeys;

  final List<String> skippedLowQuality;

  final List<int> palette;

  final Set<String> verifiedKeys;
  final Set<String> handKeys;

  /// Verified keys whose committed asset turned out to be one LabVIEW generation of several,
  /// by the key that generation now carries.
  final Map<String, String> renamed;
}

Future<PrimIconExtraction> extractPrimIcons(WidgetTester tester) async {
  await loadRealTextFont();
  final pngs = snippetCorpusPngs();
  final appDir = '${repoRoot().path}/apps/labwright_vi_inspector';
  final assetDir = Directory('$appDir/assets/prim_icons')
    ..createSync(recursive: true);
  const primClasses = {0x3a, 0x34, 0x3e, 0x44, 0x6c, 0x93, 0x172, 0xb9, 0x370};
  final samples =
      <
        String,
        List<({Uint8List rgba, int w, int h, String source, double quality})>
      >{};
  final skippedLowQuality = <String>[];
  final observedKeys = <String>{};
  final targeted =
      <
        String,
        List<({Uint8List rgba, int w, int h, int pad, String source})>
      >{};
  final versionOfSnippet = <String, int>{};
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
      final placement = comparePlacement(
        diagram: bd,
        raster: raster,
        registration: reg,
        referenceRgba: result.referenceRgba,
        width: reference.image.width,
        height: reference.image.height,
      );
      final lowQuality = placement.objects > 0 && placement.excessSupport < 0.7;
      if (lowQuality) skippedLowQuality.add(f.uri.pathSegments.last);
      final quality = placement.objects == 0 ? 0.0 : placement.excessSupport;
      final refW = reference.image.width, refH = reference.image.height;
      final name = f.uri.pathSegments.last.replaceAll('.png', '');
      final major = int.tryParse((model.version ?? '').split('.').first) ?? 0;
      versionOfSnippet[name] = major;
      const pad = 5;
      ({Uint8List rgba, int w, int h})? cropOf(HeapRect bounds) {
        final left =
            ((bounds.left - raster.content.left) * raster.scale * reg.scale +
                    reg.dx)
                .round() -
            pad;
        final top =
            ((bounds.top - raster.content.top) * raster.scale * reg.scale +
                    reg.dy)
                .round() -
            pad;
        final w = (bounds.width * raster.scale * reg.scale).round() + 2 * pad;
        final h = (bounds.height * raster.scale * reg.scale).round() + 2 * pad;
        if (left < 0 || top < 0 || left + w > refW || top + h > refH) {
          return null;
        }
        final crop = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          crop.setRange(
            y * w * 4,
            (y + 1) * w * 4,
            result.referenceRgba,
            ((top + y) * refW + left) * 4,
          );
        }
        return (rgba: crop, w: w, h: h);
      }

      for (final o in bd.objects) {
        final b = o.absBounds;
        final key = o.primResId != null
            ? 'prim${o.primResId}'
            : (primClasses.contains(o.kind)
                  ? primIconName(bdClassVariantIconKey(bd, o))
                  : null);
        if (key == null || b == null || b.width <= 0 || b.height <= 0) {
          continue;
        }
        observedKeys.add(key);
        if (kTargetedIconSamples[key]?.any(
              (s) => s.snippet == name && s.oid == o.oid,
            ) ??
            false) {
          if (cropOf(b) case final crop?) {
            (targeted[key] ??= []).add((
              rgba: crop.rgba,
              w: crop.w,
              h: crop.h,
              pad: pad,
              source: name,
            ));
          }
        }
        if (lowQuality) continue;
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
        if ((samples[key]
                    ?.where((s) => versionOfSnippet[s.source] == major)
                    .length ??
                0) >=
            8) {
          continue;
        }
        final crop = cropOf(b);
        if (crop == null) continue;
        (samples[key] ??= []).add((
          rgba: crop.rgba,
          w: crop.w,
          h: crop.h,
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

  final catalogNow = File(
    '$appDir/lib/src/prim_icon_catalog.dart',
  ).readAsStringSync();
  final verifiedKeys = {
    for (final m in RegExp(
      r"'([a-z0-9_]+)': PrimIconStatus\.verified,",
    ).allMatches(catalogNow))
      m.group(1)!,
  };
  final handKeys = {
    for (final m in RegExp(
      r"'([a-z0-9_]+)': PrimIconStatus\.verifiedHand,",
    ).allMatches(catalogNow))
      m.group(1)!,
  };
  expect(
    RegExp(r"'([a-z0-9_]+)': PrimIconStatus\.").allMatches(catalogNow).length,
    greaterThan(50),
    reason: 'kPrimIconStatus parse came back (near-)empty',
  );
  final pending = <String, ({img.Image icon, String sources})>{};
  final failed = <String, String>{};
  final included = <String, Set<String>>{};
  var round = 0;
  while (true) {
    final keys =
        samples.keys
            .where((k) => !pending.containsKey(k) && !failed.containsKey(k))
            .toList()
          ..sort();
    if (keys.isEmpty) break;
    for (final key in keys) {
      final all = samples[key]!;
      final dims = <String, int>{};
      for (final s in all) {
        dims['${s.w}x${s.h}'] = (dims['${s.w}x${s.h}'] ?? 0) + 1;
      }
      final modal =
          (dims.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
      final group = all.where((s) => '${s.w}x${s.h}' == modal).toList()
        ..sort((a, b) => b.quality.compareTo(a.quality));
      final w0 = group.first.w, h0 = group.first.h;

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
          if (ringComplete(s.rgba)) (rect: boxRectOf(s.rgba), source: s.source),
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
        final ranked = rectGroups.values.toList()
          ..sort((a, b) => b.count.compareTo(a.count));
        final win = ranked.first;
        included[key] = {...win.sources};
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

      /// The share of inked pixels of [a] and [b] (aligned by [dx], [dy]) that are the same
      /// colour; wire ink in either is left out.
      double sameArtRate(
        ({Uint8List rgba, int w, int h, String source, double quality}) a,
        ({Uint8List rgba, int w, int h, String source, double quality}) b,
        int dx,
        int dy,
      ) {
        var same = 0, counted = 0;
        for (var y = boxPad; y < boxPad + bh; y++) {
          for (var x = boxPad; x < boxPad + bw; x++) {
            final sx = x + dx, sy = y + dy;
            if (sx < 0 || sy < 0 || sx >= b.w || sy >= b.h) continue;
            final i = (y * w0 + x) * 4, j = (sy * b.w + sx) * 4;
            final aInk = inky(a.rgba, w0, x, y),
                bInk = inky(b.rgba, b.w, sx, sy);
            if (!aInk && !bInk) continue;
            final ca = (a.rgba[i] << 16) | (a.rgba[i + 1] << 8) | a.rgba[i + 2];
            final cb = (b.rgba[j] << 16) | (b.rgba[j + 1] << 8) | b.rgba[j + 2];
            if (kWireInkPalette.contains(ca) || kWireInkPalette.contains(cb))
              continue;
            counted++;
            if (ca == cb) same++;
          }
        }
        return counted == 0 ? 1 : same / counted;
      }

      var base = group.first;
      var seeded = false;
      final seeds = group.take(12).toList();
      if (seeds.length >= 2) {
        var bestAgree = 0.0;
        for (var i = 0; i < seeds.length; i++) {
          for (var j = i + 1; j < seeds.length; j++) {
            final (_, _, agree) = alignOnto(seeds[i], seeds[j]);
            if (agree > bestAgree) {
              bestAgree = agree;
              base = seeds[i];
            }
          }
        }
        seeded = bestAgree >= 0.8;
      }
      final aligned =
          <({Uint8List rgba, int w, int h, int dx, int dy, String source})>[];
      if (seeded) {
        for (final s in group) {
          final (dx, dy, agree) = alignOnto(base, s);
          if (agree < 0.8 || sameArtRate(base, s, dx, dy) < 0.97) continue;
          aligned.add((
            rgba: s.rgba,
            w: s.w,
            h: s.h,
            dx: dx,
            dy: dy,
            source: s.source,
          ));
        }
      }
      included[key] = {for (final a in aligned) a.source};
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
          if (aligned.length >= 3 && top.value * 3 < aligned.length * 2) {
            consensus[i] = consensus[i + 1] = consensus[i + 2] = 255;
            consensus[i + 3] = 255;
            continue;
          }
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
            final inside =
                c.l >= kl - 1 &&
                c.r <= kr + 1 &&
                c.t >= kt - 1 &&
                c.b <= kb + 1;
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

      String? singleSource;
      Uint8List? centredSingle() {
        var bestInk = 0;
        Uint8List? single;
        for (final s in group) {
          final copy = Uint8List.fromList(s.rgba);
          keepMainCluster(copy);
          measure(copy);
          if (r < 0) continue;
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
            singleSource = s.source;
          }
        }
        return bestInk < 60 ? null : single;
      }

      var method = seeded ? 'pair-seeded consensus' : 'single-sample fallback';
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
        included[key] = {singleSource!};
        consensus.setAll(0, single);
        measure(consensus);
      }
      if (r < 0) {
        failed[key] = 'no ink after cleaning (${group.length} samples)';
        continue;
      }
      if (l == 0 || t == 0 || r == w0 - 1 || btm == h0 - 1) {
        final single = centredSingle();
        if (single == null) {
          failed[key] =
              'cleaned ink still reaches the crop edge (wire fusion; '
              '${group.length} samples)';
          continue;
        }
        method = 'single-sample fallback after edge fusion';
        included[key] = {singleSource!};
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
      final maxW = w0 - 2 * 5 + 6, maxH = h0 - 2 * 5 + 6;
      var finalIcon = icon;
      if (finalIcon.width > maxW || finalIcon.height > maxH) {
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
    var added = false;
    for (final key in keys) {
      final inc = included[key];
      final base = key.split('@').first;
      if (inc == null || inc.isEmpty) continue;
      final all = samples[key]!;
      final left = [
        for (final s in all)
          if (!inc.contains(s.source)) s,
      ];
      if (left.length < 2) continue;
      samples['$base@${++round}'] = left;
      added = true;
    }
    if (!added) break;
  }

  final renamed = _mergeVersionClusters(
    pending: pending,
    failed: failed,
    included: included,
    versionOfSnippet: versionOfSnippet,
    verifiedKeys: {...verifiedKeys, ...handKeys},
    assetDir: assetDir,
  );

  for (final entry in kTargetedIconSamples.entries) {
    final key = entry.key;
    pending.remove(key);
    pending.removeWhere((k, _) => k.startsWith('${key}_from'));
    final crops = targeted[key] ?? const [];
    if (crops.length != entry.value.length) {
      failed[key] =
          'targeted extraction reached ${crops.length} of '
          '${entry.value.length} named instances';
      continue;
    }
    final cleaned = [
      for (final crop in crops)
        if (_cleanNodeBoxCrop(crop.rgba, crop.w, crop.h, crop.pad)
            case final art?)
          (art: art, source: crop.source),
    ];
    if (cleaned.length != crops.length) {
      failed[key] =
          'targeted cleaning left no ink on ${crops.length - cleaned.length} of the named instances';
      continue;
    }
    final first = cleaned.first.art;
    final disagreeing = cleaned
        .skip(1)
        .where(
          (c) =>
              c.art.w != first.w ||
              c.art.h != first.h ||
              c.art.dx != first.dx ||
              c.art.dy != first.dy ||
              !_sameBytes(c.art.rgba, first.rgba),
        );
    if (disagreeing.isNotEmpty) {
      failed[key] =
          'the ${cleaned.length} targeted instances do not agree byte-for-byte';
      continue;
    }
    final icon = img.Image(width: first.w, height: first.h, numChannels: 4);
    for (var y = 0; y < first.h; y++) {
      for (var x = 0; x < first.w; x++) {
        final i = (y * first.w + x) * 4;
        icon.setPixelRgba(
          x,
          y,
          first.rgba[i],
          first.rgba[i + 1],
          first.rgba[i + 2],
          first.rgba[i + 3],
        );
      }
    }
    failed.remove(key);
    pending[key] = (
      icon: icon,
      sources:
          'targeted node-box crop, ${cleaned.length} named instance'
          '${cleaned.length == 1 ? '' : 's agreeing byte-for-byte'}: '
          '${entry.value.map((s) => '${s.snippet}#${s.oid}').join(', ')} '
          '(art at dx ${first.dx}, dy ${first.dy} in the node box)',
    );
  }

  final palette = <int>{};
  for (final e in pending.values) {
    for (final px in e.icon) {
      if (px.a == 0) continue;
      palette.add((px.r.toInt() << 16) | (px.g.toInt() << 8) | px.b.toInt());
    }
  }
  final paletteList = palette.toList()..sort();

  return PrimIconExtraction(
    appDir: appDir,
    assetDir: assetDir,
    pending: pending,
    failed: failed,
    observedKeys: observedKeys,
    skippedLowQuality: skippedLowQuality,
    palette: paletteList,
    verifiedKeys: verifiedKeys,
    handKeys: handKeys,
    renamed: renamed,
  );
}

/// Folds the appearances of each key (`key`, `key@1`, …: samples that did not agree with
/// an earlier cut, from other LabVIEW majors) into generations named `key_from<major>` by
/// the first LabVIEW major each appearance comes from. A verified key's committed asset
/// names the generation it equals.
Map<String, String> _mergeVersionClusters({
  required Map<String, ({img.Image icon, String sources})> pending,
  required Map<String, String> failed,
  required Map<String, Set<String>> included,
  required Map<String, int> versionOfSnippet,
  required Set<String> verifiedKeys,
  required Directory assetDir,
}) {
  final bases = <String>{
    for (final k in [...pending.keys, ...failed.keys])
      if (k.contains('@')) k.split('@').first,
  };
  final renamed = <String, String>{};
  for (final base in bases) {
    final members = [
      for (final k in [...pending.keys, ...failed.keys])
        if (k == base || k.startsWith('$base@')) k,
    ]..sort((a, b) => (included[b]?.length ?? 0) - (included[a]?.length ?? 0));
    final candidates = [
      for (final k in members)
        if (pending[k] != null && (included[k]?.length ?? 0) >= 2) k,
    ];
    final votes = <int, Map<String, int>>{};
    for (final k in candidates) {
      for (final src in included[k]!) {
        final major = versionOfSnippet[src] ?? 0;
        (votes[major] ??= {})[k] = ((votes[major] ??= {})[k] ?? 0) + 1;
      }
    }
    final majors = votes.keys.toList()..sort();
    final runs = <({String key, int from, List<int> majors})>[];
    for (final major in majors) {
      final winner = candidates.firstWhere((k) {
        final n = votes[major]![k] ?? 0;
        return n > 0 && candidates.every((o) => (votes[major]![o] ?? 0) <= n);
      });
      if (runs.isNotEmpty && runs.last.key == winner) {
        runs.last.majors.add(major);
      } else {
        runs.add((key: winner, from: major, majors: [major]));
      }
    }
    for (var i = 0; i < runs.length;) {
      final run = runs[i];
      final support = run.majors.fold(
        0,
        (n, m) => n + (votes[m]![run.key] ?? 0),
      );
      final into = i > 0 ? i - 1 : i + 1;
      if (support >= 2 || into >= runs.length) {
        i++;
        continue;
      }
      runs[into].majors.addAll(run.majors);
      runs[into].majors.sort();
      runs.removeAt(i);
      if (i > 0 && i < runs.length && runs[i].key == runs[i - 1].key) {
        runs[i - 1].majors.addAll(runs[i].majors);
        runs[i - 1].majors.sort();
        runs.removeAt(i);
      }
    }
    for (var i = 0; i < runs.length; i++) {
      runs[i] = (
        key: runs[i].key,
        from: runs[i].majors.first,
        majors: runs[i].majors,
      );
    }
    final committed = verifiedKeys.contains(base)
        ? _committedAsset(assetDir, base)
        : null;
    final split =
        runs.map((r) => r.key).toSet().length >= 2 &&
        (committed == null ||
            runs.any(
              (r) => _sameArt(pending[r.key]!.icon, committed, tolerance: 0),
            ));
    final keep = split
        ? null
        : committed != null
        ? base
        : candidates.firstOrNull ?? base;
    if (!split) {
      final cut = pending[keep!], inc = included[keep];
      for (final k in members) {
        if (k != base) {
          pending.remove(k);
          failed.remove(k);
          included.remove(k);
        }
      }
      if (cut != null) {
        pending[base] = cut;
        included[base] = inc!;
      }
      continue;
    }
    final cuts = {for (final k in candidates) k: pending[k]!};
    for (final k in members) {
      pending.remove(k);
      failed.remove(k);
    }
    for (final run in runs) {
      final name = '${base}_from${run.from}';
      final cut = cuts[run.key]!;
      pending[name] = (
        icon: cut.icon,
        sources: '${cut.sources} [LabVIEW ${run.majors.join(', ')}]',
      );
      included[name] = included[run.key]!;
      if (committed != null &&
          !renamed.containsKey(base) &&
          _sameArt(cut.icon, committed, tolerance: 0)) {
        renamed[base] = name;
      }
    }
  }
  return renamed;
}

/// Whether two cuts are the same art: the same size and at most [tolerance] differing pixels.
bool _sameArt(img.Image a, img.Image b, {int tolerance = 12}) {
  if (a.width != b.width || a.height != b.height) return false;
  var diffs = 0;
  for (final px in a) {
    final q = b.getPixel(px.x, px.y);
    if (px.r != q.r || px.g != q.g || px.b != q.b || px.a != q.a) diffs++;
    if (diffs > tolerance) return false;
  }
  return true;
}

/// The committed asset of [key], by its file name.
img.Image? _committedAsset(Directory assetDir, String key) {
  for (final f in assetDir.listSync().whereType<File>()) {
    if (RegExp(
      '/$key(?:_(?!t\\d|r[0-9a-f]+(?:_|\\.)|from\\d)[a-z0-9-]+)?\\.png\$',
    ).hasMatch(f.path)) {
      return img.decodePng(f.readAsBytesSync());
    }
  }
  return null;
}

List<String> primIconReproErrors(PrimIconExtraction extraction) {
  final outDir = extraction.assetDir;
  final pending = extraction.pending;
  final failed = extraction.failed;
  final verifiedKeys = extraction.verifiedKeys;
  final reproErrors = <String>[];
  for (final key in verifiedKeys) {
    final files = Directory(outDir.path)
        .listSync()
        .whereType<File>()
        .where(
          (f) => RegExp(
            '/$key(?:_(?!t\\d|r[0-9a-f]+(?:_|\\.)|from\\d)[a-z0-9-]+)?\\.png\$',
          ).hasMatch(f.path),
        )
        .toList();
    if (files.isEmpty) {
      reproErrors.add('$key is marked verified but has no committed asset');
      continue;
    }
    final committed = img.decodePng(files.first.readAsBytesSync())!;
    final fresh =
        (pending[key] ?? pending[extraction.renamed[key] ?? ''])?.icon;
    if (fresh == null) {
      reproErrors.add(
        '$key is verified but the pipeline produced no extraction '
        '(${failed[key] ?? 'no extraction output'})',
      );
      continue;
    }
    if (fresh.width != committed.width || fresh.height != committed.height) {
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
  return reproErrors;
}
