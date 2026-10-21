@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_color_aliases.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// Export is opt-in (it writes files outside the build tree):
/// `flutter test test/icon_scoreboard_test.dart --tags corpus --dart-define=SCORE_DIR=<dir>`
/// writes `icon_score.txt` (per icon key: occurrences in well-registered snippets, how many
/// match the reference exactly within the icon's stamp, best and worst) and `icon_dumps.txt`
/// (the best imperfect occurrence of each key, reference beside render).
void main() {
  const scoreDir = String.fromEnvironment('SCORE_DIR');
  const keyDump = String.fromEnvironment('KEY_DUMP');
  const reviewDir = String.fromEnvironment('REVIEW_DIR');
  testWidgets('SCORE_DIR=<dir> scores every icon against the snippet references', (
    tester,
  ) async {
    if (scoreDir.isEmpty) {
      markTestSkipped('pass --dart-define=SCORE_DIR=<dir> to export');
      return;
    }
    await loadRealTextFont();
    final rows = <String, List<(String, int, int, int, String)>>{};
    final byVersion = <String, Map<String, (int, int)>>{};
    final dumps = <String, (int, String)>{};
    final crops = <String, List<ReviewCrop>>{};
    final titles = <String, String>{};
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
          final keyName = key >= 0
              ? primIconName(key)
              : primIconName(bdClassVariantIconKey(bd, o));
          final box = raster.modelRect(b);
          final id = loadedPrimIconIdOf(o, diagram: bd);
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
              if (isWireInk(refRgb)) continue;
              total++;
              final ourRgb = (ours[j] << 16) | (ours[j + 1] << 8) | ours[j + 2];
              if (!BdColorAlias.sameColor(refRgb, ourRgb)) mismatch++;
            }
          }
          if (total == 0) continue;
          final v = model.version ?? '?';
          final seen = (byVersion[keyName] ??= {})[v] ?? (0, 0);
          byVersion[keyName]![v] = (
            seen.$1 + (mismatch == 0 ? 1 : 0),
            seen.$2 + 1,
          );
          (rows[keyName] ??= []).add((
            name,
            mismatch,
            total,
            o.oid,
            '${b.width}x${b.height}${art == null ? ' NOART' : ''}',
          ));
          if (reviewDir.isNotEmpty) {
            final file =
                'crops/$keyName/${(crops[keyName]?.length ?? 0) + 1}.png';
            File('$reviewDir/$file')
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(
                reviewCropPng(
                  box: box,
                  ours: ours,
                  oursW: oursW,
                  oursH: oursH,
                  reference: rgba,
                  refW: refW,
                  refH: refH,
                  reg: reg,
                ),
              );
            titles[keyName] = switch (o.primitive?.primResId) {
              final id? => PrimOp.fromId(id)?.opName ?? '',
              null => o.objectClass.label,
            };
            (crops[keyName] ??= []).add((
              file: file,
              snippet: name,
              version: model.version ?? '?',
              oid: o.oid,
              mismatch: mismatch,
              total: total,
              size: '${b.width}x${b.height}${art == null ? ' no art' : ''}',
            ));
          }
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
        '${k.padRight(14)} n=${rs.length.toString().padLeft(3)} perfect=${perfect.toString().padLeft(3)} sizes=${rs.map((r) => r.$5).toSet().join(',')} best=${best.$2}/${best.$3} in ${best.$1} #${best.$4} worst=${worst.$2}/${worst.$3} in ${worst.$1} #${worst.$4} versions=${(byVersion[k]!.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}:${e.value.$1}/${e.value.$2}').join(' ')}',
      );
    }
    final dumpOut = StringBuffer();
    for (final d in dumps.values) {
      dumpOut.writeln(d.$2);
    }
    File('$scoreDir/icon_dumps.txt').writeAsStringSync(dumpOut.toString());
    out.writeln('keys ${keys.length} perfect-keys $perfectKeys');
    File('$scoreDir/icon_score.txt').writeAsStringSync(out.toString());
    if (reviewDir.isNotEmpty) {
      File(
        '$reviewDir/index.html',
      ).writeAsStringSync(reviewIndexHtml(crops, titles));
    }
  }, tags: 'corpus');
}

typedef ReviewCrop = ({
  String file,
  String snippet,
  String version,
  int oid,
  int mismatch,
  int total,
  String size,
});

/// The review margin around a node box and the magnification of a review crop.
const int kReviewMargin = 16;
const int kReviewScale = 3;

/// A PNG of the reference beside the render around [box] (render pixels), each magnified
/// [kReviewScale] times with [kReviewMargin] pixels of context, the reference read through
/// [reg]; pixels outside either image are grey.
List<int> reviewCropPng({
  required Rect box,
  required Uint8List ours,
  required int oursW,
  required int oursH,
  required Uint8List reference,
  required int refW,
  required int refH,
  required BdRegistration reg,
}) {
  final left = box.left.round() - kReviewMargin,
      top = box.top.round() - kReviewMargin;
  final w = box.width.round() + 2 * kReviewMargin,
      h = box.height.round() + 2 * kReviewMargin;
  const gap = 2;
  final out = img.Image(
    width: (2 * w + gap) * kReviewScale,
    height: h * kReviewScale,
  );
  img.fill(out, color: img.ColorRgb8(0x80, 0x80, 0x80));
  void blit(int originX, int Function(int x, int y) rgbAt) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final rgb = rgbAt(left + x, top + y);
        if (rgb < 0) continue;
        img.fillRect(
          out,
          x1: (originX + x) * kReviewScale,
          y1: y * kReviewScale,
          x2: (originX + x + 1) * kReviewScale - 1,
          y2: (y + 1) * kReviewScale - 1,
          color: img.ColorRgb8(rgb >> 16, (rgb >> 8) & 0xff, rgb & 0xff),
        );
      }
    }
  }

  int at(Uint8List px, int pw, int ph, int x, int y) {
    if (x < 0 || y < 0 || x >= pw || y >= ph) return -1;
    final i = (y * pw + x) * 4;
    return (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
  }

  blit(
    0,
    (x, y) => at(
      reference,
      refW,
      refH,
      (x * reg.scale + reg.dx).round(),
      (y * reg.scale + reg.dy).round(),
    ),
  );
  blit(w + gap, (x, y) => at(ours, oursW, oursH, x, y));
  return img.encodePng(out);
}

/// An HTML page of every review crop, keys with the most imperfect occurrences first and,
/// within a key, the worst occurrences first; each crop shows the reference on the left and
/// the render on the right.
String reviewIndexHtml(
  Map<String, List<ReviewCrop>> crops,
  Map<String, String> titles,
) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('"', '&quot;');
  final keys = crops.keys.toList()
    ..sort((a, b) {
      final ia = crops[a]!.where((c) => c.mismatch > 0).length,
          ib = crops[b]!.where((c) => c.mismatch > 0).length;
      return ib != ia ? ib.compareTo(ia) : a.compareTo(b);
    });
  final html = StringBuffer('''
<!doctype html>
<meta charset="utf-8">
<title>Icon review</title>
<style>
body{font:14px system-ui;margin:16px;background:#fff;color:#222}
h2{margin:32px 0 8px;font-size:18px}
h2 small{font-weight:normal;color:#666}
.row{display:flex;flex-wrap:wrap;gap:12px}
figure{margin:0;border:1px solid #ddd;padding:6px;background:#fafafa}
figure.bad{border-color:#c33}
img{display:block;image-rendering:pixelated}
figcaption{font:12px monospace;color:#444;margin-top:4px;max-width:420px}
nav a{display:inline-block;margin:0 8px 6px 0;font:12px monospace}
</style>
<h1>Icon review</h1>
<p>Each crop: reference render on the left, inspector render on the right, ${kReviewScale}× with $kReviewMargin px of context. Red border: pixels differ (color aliases and wire ink aside).</p>
<nav>
''');
  for (final k in keys) {
    final list = crops[k]!;
    final bad = list.where((c) => c.mismatch > 0).length;
    html.writeln(
      '<a href="#${esc(k)}">${esc(k)} ${esc(titles[k] ?? '')} ${list.length - bad}/${list.length}</a>',
    );
  }
  html.writeln('</nav>');
  for (final k in keys) {
    final list = crops[k]!..sort((a, b) => b.mismatch.compareTo(a.mismatch));
    final bad = list.where((c) => c.mismatch > 0).length;
    html.writeln(
      '<h2 id="${esc(k)}">${esc(k)} ${esc(titles[k] ?? '')} <small>${list.length - bad} of ${list.length} exact</small></h2>',
    );
    html.writeln('<div class="row">');
    for (final c in list) {
      html.writeln(
        '<figure class="${c.mismatch > 0 ? 'bad' : 'ok'}"><img src="${esc(c.file)}" loading="lazy">'
        '<figcaption>${esc(c.snippet)} v${esc(c.version)} #${c.oid} ${c.size}<br>'
        '${c.mismatch}/${c.total} pixels differ</figcaption></figure>',
      );
    }
    html.writeln('</div>');
  }
  return html.toString();
}
