@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'bd_wire_mask_test.dart' show kWireInkPalette;
import 'util.dart';

/// Export is opt-in (it writes files outside the build tree):
/// `flutter test test/icon_scoreboard_test.dart --tags corpus --dart-define=SCORE_DIR=<dir>`
/// writes `icon_score.txt` (per icon key: occurrences in well-registered snippets, how many
/// match the reference exactly within the icon's stamp, best and worst) and `icon_dumps.txt`
/// (the best imperfect occurrence of each key, reference beside render).
void main() {
  const scoreDir = String.fromEnvironment('SCORE_DIR');
  const keyDump = String.fromEnvironment('KEY_DUMP');
  testWidgets('SCORE_DIR=<dir> scores every icon against the snippet references', (
    tester,
  ) async {
    if (scoreDir.isEmpty) {
      markTestSkipped('pass --dart-define=SCORE_DIR=<dir> to export');
      return;
    }
    await loadRealTextFont();
    final rows = <String, List<(String, int, int, int, String)>>{};
    final dumps = <String, (int, String)>{};
    await tester.runAsync(() async {
      final icons = loadPrimIcons();
      for (final f in snippetCorpusPngs()) {
        final name = f.path.split('/').last;
        final bytes = f.readAsBytesSync();
        final ViModel model;
        try {
          model = buildViModel(extractSnippetVi(bytes)!);
        } catch (_) {
          continue;
        }
        final bd = bestBlockDiagram(model);
        if (bd == null) continue;
        final drawable = bdDrawableObjects(bd);
        final raster = await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          wires: bdVisibleWires(bd),
          drawable: drawable,
        );
        if (raster == null) continue;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
        );
        if (!result.registered || result.comparison.diffFraction > 0.08)
          continue;
        if ((result.registration.scale - 1).abs() > 0.001) continue;
        final reg = result.registration;
        final refW = result.reference.width, refH = result.reference.height;
        final rgba = result.referenceRgba;
        final ours = (await raster.image.toByteData())!.buffer.asUint8List();
        final oursW = raster.image.width, oursH = raster.image.height;
        for (final o in bd.objects) {
          final key = primIconKeyOf(o);
          final b = o.absBounds;
          if (key == null || b == null) continue;
          final terms = bd
              .childrenOf(o)
              .where((c) => c.kind == kNodeEndpointDcoKind)
              .length;
          final keyName = key >= 0
              ? primIconName(key)
              : primIconName(classVariantIconKey(o.kind, terms));
          final box = raster.modelRect(b);
          final id = loadedPrimIconIdOf(o);
          final art = id == null ? null : icons[id];
          final r = art == null
              ? box
              : primIconStampRect(box, art.width, art.height, key: id);
          var mismatch = 0, total = 0;
          for (var y = r.top.round(); y < r.bottom.round(); y++) {
            for (var x = r.left.round(); x < r.right.round(); x++) {
              final rx = (x * reg.scale + reg.dx).round(),
                  ry = (y * reg.scale + reg.dy).round();
              if (rx < 0 ||
                  ry < 0 ||
                  rx >= refW ||
                  ry >= refH ||
                  x < 0 ||
                  y < 0 ||
                  x >= oursW ||
                  y >= oursH)
                continue;
              final i = (ry * refW + rx) * 4, j = (y * oursW + x) * 4;
              final refRgb = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
              if (kWireInkPalette.contains(refRgb)) continue;
              total++;
              if (rgba[i] != ours[j] ||
                  rgba[i + 1] != ours[j + 1] ||
                  rgba[i + 2] != ours[j + 2])
                mismatch++;
            }
          }
          if (total == 0) continue;
          (rows[keyName] ??= []).add((
            name,
            mismatch,
            total,
            o.oid,
            '${b.width}x${b.height}${art == null ? ' NOART' : ''}',
          ));
          final wanted = keyName == keyDump;
          if (wanted ||
              mismatch > 0 &&
                  (dumps[keyName] == null || dumps[keyName]!.$1 > mismatch)) {
            final dump = StringBuffer(
              '--- $keyName best $name #${o.oid} mismatch $mismatch/$total box ${box.left.round()},${box.top.round()} stamp ${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()} reg ${reg.scale} ${reg.dx} ${reg.dy}\n',
            );
            for (var y = box.top.round() - 2; y < box.bottom.round() + 2; y++) {
              final a = StringBuffer(), c = StringBuffer();
              for (
                var x = box.left.round() - 2;
                x < box.right.round() + 2;
                x++
              ) {
                String cell(Uint8List px, int w, int h, {bool mapped = false}) {
                  final px0 = mapped ? (x * reg.scale + reg.dx).round() : x,
                      py0 = mapped ? (y * reg.scale + reg.dy).round() : y;
                  if (px0 < 0 || py0 < 0 || px0 >= w || py0 >= h) return ' ~ ';
                  final j = (py0 * w + px0) * 4;
                  final rr = px[j], gg = px[j + 1], bb = px[j + 2];
                  final grey = (rr + gg + bb) ~/ 3;
                  final neutral = (rr - bb).abs() < 30 && (rr - gg).abs() < 30;
                  return rr == 255 && gg == 255 && bb == 255
                      ? ' . '
                      : neutral
                      ? grey.toRadixString(16).padLeft(2, '0') + ' '
                      : ' c ';
                }

                a.write(cell(rgba, refW, refH, mapped: true));
                c.write(cell(ours, oursW, oursH));
              }
              dump.writeln('${y.toString().padLeft(4)} $a | $c');
            }
            dumps[wanted ? '$keyName $name #${o.oid}' : keyName] = (
              mismatch,
              dump.toString(),
            );
          }
        }
      }
    });
    final out = StringBuffer();
    final keys = rows.keys.toList()..sort();
    var perfectKeys = 0;
    for (final k in keys) {
      final rs = rows[k]!;
      final perfect = rs.where((r) => r.$2 == 0).length;
      if (perfect == rs.length) perfectKeys++;
      rs.sort((a, b) => b.$2.compareTo(a.$2));
      final worst = rs.first, best = rs.last;
      out.writeln(
        '${k.padRight(14)} n=${rs.length.toString().padLeft(3)} perfect=${perfect.toString().padLeft(3)} sizes=${rs.map((r) => r.$5).toSet().join(',')} best=${best.$2}/${best.$3} in ${best.$1} #${best.$4} worst=${worst.$2}/${worst.$3} in ${worst.$1} #${worst.$4}',
      );
    }
    final dumpOut = StringBuffer();
    for (final d in dumps.values) {
      dumpOut.writeln(d.$2);
    }
    File('$scoreDir/icon_dumps.txt').writeAsStringSync(dumpOut.toString());
    out.writeln('keys ${keys.length} perfect-keys $perfectKeys');
    File('$scoreDir/icon_score.txt').writeAsStringSync(out.toString());
  }, tags: 'corpus');
}
