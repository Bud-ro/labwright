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
          if ((samples[key]?.length ?? 0) >= 8) continue;
          final left =
              ((b.left - raster.content.left) * raster.scale * reg.scale +
                      reg.dx)
                  .round() -
              1;
          final top =
              ((b.top - raster.content.top) * raster.scale * reg.scale + reg.dy)
                  .round() -
              1;
          final w = (b.width * raster.scale * reg.scale).round() + 2;
          final h = (b.height * raster.scale * reg.scale).round() + 2;
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
    final keys = samples.keys.toList()..sort();
    for (final key in keys) {
      final all = samples[key]!;
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
        for (var dy = -3; dy <= 3; dy++) {
          for (var dx = -3; dx <= 3; dx++) {
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
      // Trim to ink.
      int l = w0, t = h0, r = -1, btm = -1;
      for (var y = 0; y < h0; y++) {
        for (var x = 0; x < w0; x++) {
          if (!inky(consensus, w0, x, y)) continue;
          if (x < l) l = x;
          if (x > r) r = x;
          if (y < t) t = y;
          if (y > btm) btm = y;
        }
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
      final primId = key.startsWith('prim')
          ? int.parse(key.substring(4))
          : null;
      final op = primId == null ? null : PrimOp.fromId(primId);
      final classCode = key.startsWith('class')
          ? int.parse(key.substring(5))
          : null;
      File('${outDir.path}/$key.png').writeAsBytesSync(img.encodePng(icon));
      final label =
          op?.opName ??
          (classCode != null
              ? 'class 0x${classCode.toRadixString(16)}'
              : '(uncatalogued)');
      final sources = group.map((s) => s.source).toSet().join(', ');
      manifest.writeln('| $key.png | $label | ${w}x$h | $sources |');
      written++;
    }
    File('${outDir.path}/MANIFEST.md').writeAsStringSync(manifest.toString());
    // ignore: avoid_print
    print('wrote $written icon assets to ${outDir.path}');
  });
}
