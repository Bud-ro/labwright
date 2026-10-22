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
/// each distinct appearance of the node box in LabVIEW's reference renders, cropped at natural
/// size with [kIconReviewPad] pixels around the box, color aliases canonicalised and grid dots
/// cleared, with how often and where it appears. `index.json` describes them all.
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
          final raster = await rasteriseBlockDiagram(bd, scale: 1.0, margin: 2);
          if (raster == null) continue;
          final reference = await decodeReferenceImage(bytes);
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(bd, raster),
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
          for (final o in bd.objects) {
            final b = o.absBounds;
            final key = o.primitive?.primResId != null
                ? 'prim${o.primitive?.primResId}'
                : (primClasses.contains(o.kind)
                      ? primIconName(bdClassVariantIconKey(bd, o))
                      : null);
            if (key == null || b == null || b.width <= 0 || b.height <= 0) {
              continue;
            }
            final left =
                ((b.left - raster.content.left) * raster.scale * reg.scale +
                        reg.dx)
                    .round() -
                kIconReviewPad;
            final top =
                ((b.top - raster.content.top) * raster.scale * reg.scale +
                        reg.dy)
                    .round() -
                kIconReviewPad;
            final w = b.width + 2 * kIconReviewPad,
                h = b.height + 2 * kIconReviewPad;
            if (left < 0 || top < 0 || left + w > refW || top + h > refH) {
              continue;
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
            var anc = bd.byId[o.parentOid ?? -1];
            var hops = 0, disabled = false;
            while (anc != null && hops++ < 12) {
              if (anc.kind == 0xcd) {
                disabled = true;
                break;
              }
              anc = bd.byId[anc.parentOid ?? -1];
            }
            final resolved = loadedPrimIconIdOf(o, diagram: bd);
            final variant = (variants[key] ??= {}).putIfAbsent(
              base64Encode(crop),
              () => _Variant(
                rgba: crop,
                width: w,
                height: h,
                hard: isHardEdgedCrop(crop, w, h, kIconReviewPad),
                ink: hasIconInk(crop, w, h, kIconReviewPad),
                generation: resolved == null ? null : primIconName(resolved),
              ),
            );
            variant.sources.add((
              snippet: name,
              version: version,
              oid: o.oid,
              lowQuality: lowQuality,
              disabled: disabled,
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
          final (boxW, boxH, canvas, stamp) = _stampedAsset(
            art.width,
            art.height,
            art.rgba,
            commonSize,
            id,
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
            'stamp': [
              stamp.left.round() - kIconReviewPad,
              stamp.top.round() - kIconReviewPad,
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
          final (boxW, boxH, canvas, stamp) = _stampedAsset(
            art.width,
            art.height,
            rgba,
            commonSize,
            parsePrimIconName(name)!,
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
            'stamp': [
              stamp.left.round() - kIconReviewPad,
              stamp.top.round() - kIconReviewPad,
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
          refs.add({
            'file': file,
            'width': v.width,
            'height': v.height,
            'count': v.sources.length,
            'hard': v.hard,
            'ink': v.ink,
            'generation': v.generation,
            'versions': (v.sources.map((s) => s.version).toSet().toList()
              ..sort()),
            'lowQuality': v.sources.every((s) => s.lowQuality),
            'disabled': v.sources.every((s) => s.disabled),
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
          'occurrences': occurrences,
          'icons': index,
        }),
      );
    },
  );
}

/// [art] over a white node box of [commonSize] (else the art's own size) with
/// [kIconReviewPad] around it, placed as the painter stamps icon [id].
(int, int, img.Image, Rect) _stampedAsset(
  int artW,
  int artH,
  Uint8List rgba,
  List<int>? commonSize,
  int id,
) {
  final boxW = commonSize?[0] ?? artW, boxH = commonSize?[1] ?? artH;
  final stamp = primIconStampRect(
    Rect.fromLTWH(
      kIconReviewPad.toDouble(),
      kIconReviewPad.toDouble(),
      boxW.toDouble(),
      boxH.toDouble(),
    ),
    artW,
    artH,
    key: id,
  );
  final canvas = img.Image(
    width: boxW + 2 * kIconReviewPad,
    height: boxH + 2 * kIconReviewPad,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < artH; y++) {
    for (var x = 0; x < artW; x++) {
      final i = (y * artW + x) * 4;
      final a = rgba[i + 3];
      if (a == 0) continue;
      final cx = stamp.left.round() + x, cy = stamp.top.round() + y;
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
  return (boxW, boxH, canvas, stamp);
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
    required this.hard,
    required this.ink,
    required this.generation,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final bool hard;
  final bool ink;
  final String? generation;
  final sources =
      <
        ({
          String snippet,
          String version,
          int oid,
          bool lowQuality,
          bool disabled,
        })
      >[];
}
