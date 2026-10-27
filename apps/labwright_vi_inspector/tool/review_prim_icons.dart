import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_color_aliases.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

import '../test/util.dart';
import 'prim_icon_extraction.dart';

/// The background pixels kept around a node box in a review crop.
const int kIconReviewPad = 1;

/// Writes an icon review set to a directory:
///     flutter test tool/review_prim_icons.dart --dart-define=ICON_REVIEW_DIR=<dir>
///
/// For every icon key the snippet corpus shows or an asset exists for, `<key>/asset_<name>.png`
/// is each committed generation of the art stamped in a white node box, and `<key>/<n>.png`
/// each distinct appearance of a drawn node's box in LabVIEW's reference renders, cropped at
/// natural size with [kIconReviewPad] pixels around the box, color aliases canonicalised and
/// grid dots cleared, with how often and where it appears, and `<key>/<n>_cut.png` the icon
/// ink the extraction cuts from that appearance on its own, placed in the box. `index.json`
/// describes them all, each appearance with how the committed art sits in it (`match`, see
/// [_matchOf]).
void main() {
  const reviewDir = String.fromEnvironment('ICON_REVIEW_DIR');
  testWidgets(
    'ICON_REVIEW_DIR=<dir> exports every icon beside its references',
    (tester) async {
      if (reviewDir.isEmpty) {
        markTestSkipped('pass --dart-define=ICON_REVIEW_DIR=<dir> to export');
        return;
      }
      await loadRealTextFont();
      final icons = loadPrimIcons();
      const primClasses = {
        0x3a,
        0x34,
        0x3e,
        0x44,
        0x6c,
        0x93,
        0x172,
        0xb9,
        0x370,
      };
      final variants = <String, Map<String, _Variant>>{};
      final boxSizes = <String, Map<String, int>>{};
      var snippets = 0, registered = 0, occurrences = 0;
      final watermarked = <String>[];
      await tester.runAsync(() async {
        for (final f in snippetCorpusPngs()) {
          final bytes = f.readAsBytesSync();
          final vi = extractSnippetVi(bytes);
          if (vi == null) continue;
          final ViModel model;
          try {
            model = buildViModel(vi);
          } catch (_) {
            continue;
          }
          final bd = bestBlockDiagram(model);
          if (bd == null) continue;
          snippets++;
          final hasWatermark = model.saveRecord?.rendersWatermark ?? false;
          if (hasWatermark) {
            watermarked.add(f.uri.pathSegments.last.replaceAll('.png', ''));
          }
          final drawable = bdDrawableObjects(bd);
          final raster = await rasteriseBlockDiagram(
            bd,
            primIcons: icons,
            scale: 1.0,
            margin: 2,
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
            exactRects: bdPrimIconStampRects(bd, raster, drawable: drawable),
          );
          if (!result.registered) continue;
          final reg = result.registration;
          if ((reg.scale - 1).abs() > 0.001) continue;
          registered++;
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
          final refW = reference.image.width, refH = reference.image.height;
          final name = f.uri.pathSegments.last.replaceAll('.png', '');
          final version = model.version ?? '?';
          for (final o in drawable) {
            final b = o.absBounds;
            final key = iconReviewKeyOf(bd, o, primClasses);
            if (key == null || b == null || b.width <= 0 || b.height <= 0) {
              continue;
            }
            final resolved = loadedPrimIconIdOf(o, diagram: bd);
            final art = resolved == null ? null : icons[resolved];
            final region = _regionOf(b.width, b.height, art, resolved);
            final boxLeft =
                ((b.left - raster.content.left) * raster.scale * reg.scale +
                        reg.dx)
                    .round();
            final boxTop =
                ((b.top - raster.content.top) * raster.scale * reg.scale +
                        reg.dy)
                    .round();
            final left = boxLeft + region.left.round() - kIconReviewPad;
            final top = boxTop + region.top.round() - kIconReviewPad;
            final w = region.width.round() + 2 * kIconReviewPad,
                h = region.height.round() + 2 * kIconReviewPad;
            if (left + w <= 0 || top + h <= 0 || left >= refW || top >= refH) {
              continue;
            }
            final crop = _cropReference(
              result.referenceRgba,
              refW,
              refH,
              left,
              top,
              w,
              h,
            );
            final boxRect = [
              kIconReviewPad - region.left.round(),
              kIconReviewPad - region.top.round(),
              b.width,
              b.height,
            ];
            var anc = bd.byId[o.parentOid ?? -1];
            var hops = 0, disabled = false;
            while (anc != null && hops++ < 12) {
              if (anc.kind == 0xcd) {
                disabled = true;
                break;
              }
              anc = bd.byId[anc.parentOid ?? -1];
            }
            final variant = (variants[key] ??= {}).putIfAbsent(
              base64Encode(crop),
              () => _Variant(
                rgba: crop,
                width: w,
                height: h,
                boxRect: boxRect,
                hard: isHardEdgedCrop(crop, w, h, kIconReviewPad, key: key),
                ink: hasIconInk(crop, w, h, kIconReviewPad),
                generation: resolved == null ? null : primIconName(resolved),
                cut: _cutOf(
                  key,
                  result.referenceRgba,
                  refW,
                  refH,
                  boxLeft,
                  boxTop,
                  b.width,
                  b.height,
                ),
              ),
            );
            variant.sources.add((
              snippet: name,
              version: version,
              oid: o.oid,
              lowQuality: lowQuality,
              disabled: disabled,
              watermarked: hasWatermark,
            ));
            final size = '${b.width}x${b.height}';
            (boxSizes[key] ??= {})[size] = (boxSizes[key]![size] ?? 0) + 1;
            occurrences++;
          }
        }
      });
      final byBase = <String, List<int>>{};
      for (final id in icons.keys) {
        final name = primIconName(id);
        (byBase[name.replaceFirst(RegExp(r'_from\d+$'), '')] ??= []).add(id);
      }
      final keys = {...variants.keys, ...byBase.keys}.toList()..sort();
      final index = <Map<String, Object?>>[];
      for (final key in keys) {
        Directory('$reviewDir/$key').createSync(recursive: true);
        final sizes = boxSizes[key] ?? {};
        final commonSize = sizes.isEmpty
            ? null
            : (sizes.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                  .first
                  .key
                  .split('x')
                  .map(int.parse)
                  .toList();
        final assets = <Map<String, Object?>>[];
        for (final id in byBase[key] ?? const <int>[]) {
          final art = icons[id]!;
          final name = primIconName(id);
          final (boxW, boxH, canvas, stamp, boxAt) = _stampedAsset(
            art.width,
            art.height,
            art.rgba,
            commonSize,
            id,
            art,
          );
          final file = '$key/asset_$name.png';
          File('$reviewDir/$file').writeAsBytesSync(img.encodePng(canvas));
          assets.add({
            'name': name,
            'file': file,
            'status': kPrimIconStatus[name]?.name,
            'colors': _colorsOf(art.rgba),
            'width': art.width,
            'height': art.height,
            'box': [boxW, boxH],
            'boxRect': [boxAt[0], boxAt[1], boxW, boxH],
            'stamp': [
              stamp.left.round() - boxAt[0],
              stamp.top.round() - boxAt[1],
            ],
          });
        }
        for (final MapEntry(key: name, value: status)
            in kPrimIconStatus.entries) {
          if (status != PrimIconStatus.rejected ||
              name.replaceFirst(RegExp(r'_from\d+$'), '') != key) {
            continue;
          }
          final png = _committedAssetFile(name);
          if (png == null) continue;
          final art = img.decodePng(png.readAsBytesSync())!;
          final rgba = art.convert(numChannels: 4).toUint8List();
          final (boxW, boxH, canvas, stamp, boxAt) = _stampedAsset(
            art.width,
            art.height,
            rgba,
            commonSize,
            parsePrimIconName(name)!,
            null,
          );
          final file = '$key/asset_$name.png';
          File('$reviewDir/$file').writeAsBytesSync(img.encodePng(canvas));
          assets.add({
            'name': name,
            'file': file,
            'status': status.name,
            'colors': _colorsOf(rgba),
            'width': art.width,
            'height': art.height,
            'box': [boxW, boxH],
            'boxRect': [boxAt[0], boxAt[1], boxW, boxH],
            'stamp': [
              stamp.left.round() - boxAt[0],
              stamp.top.round() - boxAt[1],
            ],
          });
        }
        final list = (variants[key] ?? {}).values.toList()
          ..sort((a, b) => b.sources.length.compareTo(a.sources.length));
        final refs = <Map<String, Object?>>[];
        for (var i = 0; i < list.length; i++) {
          final v = list[i];
          final image = img.Image.fromBytes(
            width: v.width,
            height: v.height,
            bytes: v.rgba.buffer,
            numChannels: 4,
          );
          final file = '$key/${i + 1}.png';
          File('$reviewDir/$file').writeAsBytesSync(img.encodePng(image));
          final cut = v.cut;
          Map<String, Object?>? cutEntry;
          if (cut != null) {
            final canvas = img.Image(width: v.width, height: v.height);
            img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
            _stampOver(
              canvas,
              cut.rgba,
              cut.w,
              cut.h,
              v.boxRect[0] + cut.dx,
              v.boxRect[1] + cut.dy,
            );
            final cutFile = '$key/${i + 1}_cut.png';
            File('$reviewDir/$cutFile').writeAsBytesSync(img.encodePng(canvas));
            cutEntry = {
              'file': cutFile,
              'width': cut.w,
              'height': cut.h,
              'at': [cut.dx, cut.dy],
              'colors': _colorsOf(cut.rgba),
            };
          }
          final matchedId = (byBase[key] ?? const <int>[]).isEmpty
              ? null
              : byBase[key]!.firstWhere(
                  (id) => primIconName(id) == v.generation,
                  orElse: () => byBase[key]!.first,
                );
          refs.add({
            'file': file,
            'width': v.width,
            'height': v.height,
            'boxRect': v.boxRect,
            'match': matchedId == null
                ? null
                : _matchOf(v, matchedId, icons[matchedId]!),
            'count': v.sources.length,
            'hard': v.hard,
            'ink': v.ink,
            'generation': v.generation,
            'cut': cutEntry,
            'tier': _tierOf(v),
            'versions': (v.sources.map((s) => s.version).toSet().toList()
              ..sort()),
            'lowQuality': v.sources.every((s) => s.lowQuality),
            'disabled': v.sources.every((s) => s.disabled),
            'watermarked': v.sources.every((s) => s.watermarked),
            'sources': [
              for (final s in v.sources.take(12))
                '${s.snippet} v${s.version} #${s.oid}',
            ],
          });
        }
        final primId = key.startsWith('prim')
            ? int.tryParse(key.substring(4))
            : null;
        final op = primId == null ? null : PrimOp.fromId(primId);
        index.add({
          'key': key,
          'title': op?.opName,
          'assets': assets,
          'references': refs,
          'occurrences': list.fold<int>(0, (n, v) => n + v.sources.length),
        });
      }
      File('$reviewDir/index.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert({
          'pad': kIconReviewPad,
          'snippets': snippets,
          'registered': registered,
          'watermarked': watermarked,
          'occurrences': occurrences,
          'icons': index,
        }),
      );
    },
  );
}

/// The area a crop of a node box [boxW] by [boxH] covers, relative to the box: the box itself
/// and, when the painter stamps [art] beyond it, the stamp too.
Rect _regionOf(int boxW, int boxH, PrimIconArt? art, int? id) {
  final box = Rect.fromLTWH(0, 0, boxW.toDouble(), boxH.toDouble());
  if (art == null || id == null) return box;
  return box.expandToInclude(
    primIconStampRect(box, art.width, art.height, key: id),
  );
}

/// [art] over a white node box of [commonSize] (else the art's own size) with
/// [kIconReviewPad] around it, placed as the painter stamps icon [id]; the canvas covers the
/// box and the stamp. Returns the box's size, the canvas, the stamp and the box's offset in
/// the canvas.
(int, int, img.Image, Rect, List<int>) _stampedAsset(
  int artW,
  int artH,
  Uint8List rgba,
  List<int>? commonSize,
  int id,
  PrimIconArt? art,
) {
  final boxW = commonSize?[0] ?? artW, boxH = commonSize?[1] ?? artH;
  final region = _regionOf(boxW, boxH, art, id);
  final boxAt = [
    kIconReviewPad - region.left.round(),
    kIconReviewPad - region.top.round(),
  ];
  final stamp = primIconStampRect(
    Rect.fromLTWH(
      boxAt[0].toDouble(),
      boxAt[1].toDouble(),
      boxW.toDouble(),
      boxH.toDouble(),
    ),
    artW,
    artH,
    key: id,
  );
  final canvas = img.Image(
    width: region.width.round() + 2 * kIconReviewPad,
    height: region.height.round() + 2 * kIconReviewPad,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  _stampOver(canvas, rgba, artW, artH, stamp.left.round(), stamp.top.round());
  return (boxW, boxH, canvas, stamp, boxAt);
}

/// Composites the [artW] by [artH] RGBA [rgba] over the white [canvas] with its top-left at
/// ([left], [top]); pixels outside the canvas are dropped.
void _stampOver(
  img.Image canvas,
  Uint8List rgba,
  int artW,
  int artH,
  int left,
  int top,
) {
  for (var y = 0; y < artH; y++) {
    for (var x = 0; x < artW; x++) {
      final i = (y * artW + x) * 4;
      final a = rgba[i + 3];
      if (a == 0) continue;
      final cx = left + x, cy = top + y;
      if (cx < 0 || cy < 0 || cx >= canvas.width || cy >= canvas.height) {
        continue;
      }
      int over(int c) => (c * a + 255 * (255 - a)) ~/ 255;
      canvas.setPixelRgb(
        cx,
        cy,
        over(rgba[i]),
        over(rgba[i + 1]),
        over(rgba[i + 2]),
      );
    }
  }
}

/// The [w] by [h] window of the reference at ([left], [top]) as opaque RGBA, white where
/// the window leaves the image, grid dots cleared and colour aliases canonicalised.
Uint8List _cropReference(
  Uint8List referenceRgba,
  int refW,
  int refH,
  int left,
  int top,
  int w,
  int h,
) {
  final crop = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  for (var y = 0; y < h; y++) {
    final sy = top + y;
    if (sy < 0 || sy >= refH) continue;
    final x0 = left < 0 ? -left : 0;
    final x1 = left + w > refW ? refW - left : w;
    if (x1 <= x0) continue;
    crop.setRange(
      (y * w + x0) * 4,
      (y * w + x1) * 4,
      referenceRgba,
      (sy * refW + left + x0) * 4,
    );
  }
  for (var i = 0; i < crop.length; i += 4) {
    final rgb = (crop[i] << 16) | (crop[i + 1] << 8) | crop[i + 2];
    final canonical = rgb == kDiagramGridDotRgb
        ? 0xffffff
        : BdColorAlias.canonicalRgb(rgb);
    crop[i] = canonical >> 16;
    crop[i + 1] = (canonical >> 8) & 0xff;
    crop[i + 2] = canonical & 0xff;
    crop[i + 3] = 0xff;
  }
  return crop;
}

/// What the extraction cuts from this one appearance of [key]'s node box on its own, see
/// [cleanNodeBoxCrop]; null when the box holds no icon ink.
({Uint8List rgba, int w, int h, int dx, int dy})? _cutOf(
  String key,
  Uint8List referenceRgba,
  int refW,
  int refH,
  int boxLeft,
  int boxTop,
  int boxW,
  int boxH,
) {
  const pad = kPrimIconCropPad;
  final w = boxW + 2 * pad, h = boxH + 2 * pad;
  final crop = _cropReference(
    referenceRgba,
    refW,
    refH,
    boxLeft - pad,
    boxTop - pad,
    w,
    h,
  );
  if (!hasIconInk(crop, w, h, pad)) return null;
  return cleanNodeBoxCrop(crop, w, h, pad, (rgb) => isForeignInk(key, rgb));
}

/// Where and how well the committed [art] of icon [id] appears in reference crop [v]:
/// `exact` when every art pixel matches at the painter's stamp, `near` when at least 95% do
/// (coercion dots, wires and option markers over the art), `occluded` when at least 80% do,
/// `shifted` when fewer do but 95% match at an offset of up to [kIconMatchSearch] pixels,
/// `absent` otherwise; `fraction` is the share matching at the stamp and `at` the offset of
/// the best match found.
Map<String, Object?> _matchOf(_Variant v, int id, PrimIconArt art) {
  final box = Rect.fromLTWH(
    v.boxRect[0].toDouble(),
    v.boxRect[1].toDouble(),
    v.boxRect[2].toDouble(),
    v.boxRect[3].toDouble(),
  );
  final stamp = primIconStampRect(box, art.width, art.height, key: id);
  final sx = stamp.left.round(), sy = stamp.top.round();
  double fractionAt(int dx, int dy) {
    var ok = 0, total = 0;
    for (var y = 0; y < art.height; y++) {
      for (var x = 0; x < art.width; x++) {
        final a = (y * art.width + x) * 4;
        if (art.rgba[a + 3] == 0) continue;
        total++;
        final cx = sx + dx + x, cy = sy + dy + y;
        if (cx < 0 || cy < 0 || cx >= v.width || cy >= v.height) continue;
        final r = (cy * v.width + cx) * 4;
        if (art.rgba[a] == v.rgba[r] &&
            art.rgba[a + 1] == v.rgba[r + 1] &&
            art.rgba[a + 2] == v.rgba[r + 2]) {
          ok++;
        }
      }
    }
    return total == 0 ? 0 : ok / total;
  }

  final here = fractionAt(0, 0);
  var best = here, bestDx = 0, bestDy = 0;
  if (here < 1) {
    for (var dy = -kIconMatchSearch; dy <= kIconMatchSearch; dy++) {
      for (var dx = -kIconMatchSearch; dx <= kIconMatchSearch; dx++) {
        if (dx == 0 && dy == 0) continue;
        final f = fractionAt(dx, dy);
        if (f > best) {
          best = f;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }
  }
  final kind = here >= 1
      ? 'exact'
      : here >= 0.95
      ? 'near'
      : here >= 0.8
      ? 'occluded'
      : best >= 0.95
      ? 'shifted'
      : 'absent';
  return {
    'kind': kind,
    'fraction': double.parse(here.toStringAsFixed(3)),
    'at': [bestDx, bestDy],
    'best': double.parse(best.toStringAsFixed(3)),
  };
}

/// How far [_matchOf] looks for the art around the painter's stamp.
const int kIconMatchSearch = 8;

/// How the extraction treats the appearances of [v]: `watermarked`, `disabled` and `blank`
/// renders are never harvested, `low registration` ones serve only keys no other snippet
/// shows, `anti-aliased` ones only keys with no hard-edged render, `hard-edged` ones vote.
String _tierOf(_Variant v) {
  if (v.sources.every((s) => s.watermarked)) return 'watermarked';
  if (v.sources.every((s) => s.disabled)) return 'disabled';
  if (!v.ink) return 'blank';
  if (v.sources.every((s) => s.lowQuality)) return 'low registration';
  if (!v.hard) return 'anti-aliased';
  return 'hard-edged';
}

/// The distinct colors of the opaque pixels in [rgba], as `rrggbb`, sorted.
List<String> _colorsOf(Uint8List rgba) {
  final seen = <int>{};
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] == 0) continue;
    seen.add((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  return [
    for (final c in seen.toList()..sort()) c.toRadixString(16).padLeft(6, '0'),
  ];
}

/// The committed PNG of icon [name] under assets/prim_icons, by file name.
File? _committedAssetFile(String name) {
  final dir = Directory(
    '${repoRoot().path}/apps/labwright_vi_inspector/assets/prim_icons',
  );
  for (final f in dir.listSync().whereType<File>()) {
    if (RegExp(
      '/$name(?:_(?!t\\d|r[0-9a-f]+(?:_|\\.)|from\\d)[a-z0-9-]+)?\\.png\$',
    ).hasMatch(f.path)) {
      return f;
    }
  }
  return null;
}

class _Variant {
  _Variant({
    required this.rgba,
    required this.width,
    required this.height,
    required this.boxRect,
    required this.hard,
    required this.ink,
    required this.generation,
    required this.cut,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// The node box within the crop, as left, top, width, height.
  final List<int> boxRect;
  final bool hard;
  final bool ink;
  final String? generation;

  /// The icon ink this appearance yields on its own, placed in the node box, see [_cutOf].
  final ({Uint8List rgba, int w, int h, int dx, int dy})? cut;
  final sources =
      <
        ({
          String snippet,
          String version,
          int oid,
          bool lowQuality,
          bool disabled,
          bool watermarked,
        })
      >[];
}
