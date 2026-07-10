import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Harvests primitive-icon crops from LabVIEW's own renders: every snippet is
/// registered against its embedded reference, and each primitive node's box
/// is cut out of the REFERENCE pixels — LabVIEW's actual icon art, keyed by
/// the node's decoded primResID. Up to three samples per id land in
/// `reference/prim_icons/` beside a manifest, for eyeball verification before
/// any icon is stamped onto renders.
///
/// Generation is opt-in (it writes into the repo):
/// `flutter test test/extract_prim_icons_test.dart --dart-define=EXTRACT_PRIM_ICONS=1`
void main() {
  const enabled = String.fromEnvironment('EXTRACT_PRIM_ICONS');
  testWidgets('extract primitive icon crops from snippet references', (
    tester,
  ) async {
    if (enabled.isEmpty) {
      markTestSkipped('pass --dart-define=EXTRACT_PRIM_ICONS=1 to generate');
      return;
    }
    await loadRealTextFont();
    final pngs = snippetCorpusPngs();
    if (pngs.isEmpty) return;
    final outDir = repoDir('apps/labwright_vi_inspector')!.path;
    final iconsDir = Directory('$outDir/reference/prim_icons')
      ..createSync(recursive: true);
    final samplesPerId = <int, int>{};
    final manifest = StringBuffer(
      '# Primitive icon crops\n\n'
      'Cut from LabVIEW\'s own renders embedded in the snippet corpus, at the\n'
      'registered box of each primitive node with a decoded primResID. For\n'
      'eyeball verification: an icon is good when it shows exactly the\n'
      'primitive\'s art with no neighbouring ink.\n\n'
      '| id | op | file | source |\n|---|---|---|---|\n',
    );
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
        final name = f.uri.pathSegments.last.replaceAll('.png', '');
        for (final o in bd.objects) {
          final id = o.primResId;
          final b = o.absBounds;
          if (id == null || b == null || b.width <= 0 || b.height <= 0) {
            continue;
          }
          if ((samplesPerId[id] ?? 0) >= 3) continue;
          // Diagram → render px → reference px under the locked registration.
          double rx(num x) =>
              (x - raster.content.left + 0) * raster.scale * reg.scale + reg.dx;
          double ry(num y) =>
              (y - raster.content.top + 0) * raster.scale * reg.scale + reg.dy;
          final left = rx(b.left).round() - 1;
          final top = ry(b.top).round() - 1;
          final w = (b.width * raster.scale * reg.scale).round() + 2;
          final h = (b.height * raster.scale * reg.scale).round() + 2;
          if (left < 0 ||
              top < 0 ||
              left + w > reference.image.width ||
              top + h > reference.image.height) {
            continue;
          }
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawImageRect(
            reference.image,
            ui.Rect.fromLTWH(
              left.toDouble(),
              top.toDouble(),
              w.toDouble(),
              h.toDouble(),
            ),
            ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            ui.Paint(),
          );
          final crop = await recorder.endRecording().toImage(w, h);
          final n = samplesPerId[id] = (samplesPerId[id] ?? 0) + 1;
          final op = PrimOp.fromId(id);
          final slug = (op?.opName ?? 'unnamed').toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]+'),
            '-',
          );
          final file = 'prim${id}_$slug.$n.png';
          File(
            '${iconsDir.path}/$file',
          ).writeAsBytesSync(await imageToPng(crop));
          manifest.writeln(
            '| $id | ${op?.opName ?? '(uncatalogued)'} | $file | $name |',
          );
        }
      }
      File(
        '${iconsDir.path}/MANIFEST.md',
      ).writeAsStringSync(manifest.toString());
    });
    // ignore: avoid_print
    print('wrote ${samplesPerId.length} distinct prim ids to ${iconsDir.path}');
  });
}
