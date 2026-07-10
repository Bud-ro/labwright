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
    // id -> candidate crops (raw RGBA + dims + source name).
    final samples =
        <int, List<({Uint8List rgba, int w, int h, String source})>>{};
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
          final id = o.primResId;
          final b = o.absBounds;
          if (id == null || b == null || b.width <= 0 || b.height <= 0)
            continue;
          if ((samples[id]?.length ?? 0) >= 5) continue;
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
          (samples[id] ??= []).add((rgba: crop, w: w, h: h, source: name));
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
      'test/extract_prim_icons_test.dart): the cleanest registered node crop\n'
      'per primResID, trimmed to its ink, exterior background transparent.\n'
      'Hand-edits welcome — the painter stamps these at natural size.\n\n'
      '| id | op | size | source |\n|---|---|---|---|\n',
    );
    var written = 0;
    final ids = samples.keys.toList()..sort();
    for (final id in ids) {
      // The cleanest sample: smallest ink bounding box (neighbouring ink
      // inflates the box; LabVIEW draws the same icon everywhere).
      ({Uint8List rgba, int w, int h, String source})? best;
      var bestArea = 1 << 30;
      var bestBox = (l: 0, t: 0, r: 0, b: 0);
      for (final s in samples[id]!) {
        int l = s.w, t = s.h, r = -1, btm = -1;
        for (var y = 0; y < s.h; y++) {
          for (var x = 0; x < s.w; x++) {
            if (!inky(s.rgba, s.w, x, y)) continue;
            if (x < l) l = x;
            if (x > r) r = x;
            if (y < t) t = y;
            if (y > btm) btm = y;
          }
        }
        if (r < 0) continue;
        final area = (r - l + 1) * (btm - t + 1);
        if (area < bestArea) {
          bestArea = area;
          best = s;
          bestBox = (l: l, t: t, r: r, b: btm);
        }
      }
      if (best == null) continue;
      final w = bestBox.r - bestBox.l + 1, h = bestBox.b - bestBox.t + 1;
      final icon = img.Image(width: w, height: h, numChannels: 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = ((bestBox.t + y) * best.w + bestBox.l + x) * 4;
          icon.setPixelRgba(
            x,
            y,
            best.rgba[i],
            best.rgba[i + 1],
            best.rgba[i + 2],
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
      final op = PrimOp.fromId(id);
      File('${outDir.path}/prim$id.png').writeAsBytesSync(img.encodePng(icon));
      manifest.writeln(
        '| $id | ${op?.opName ?? '(uncatalogued)'} | ${w}x$h | ${best.source} |',
      );
      written++;
    }
    File('${outDir.path}/MANIFEST.md').writeAsStringSync(manifest.toString());
    // ignore: avoid_print
    print('wrote $written icon assets to ${outDir.path}');
  });
}
