import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_color_aliases.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/prim_icon_border.dart';

import '../test/util.dart';

/// Keys whose samples, alignment and consensus are written as PNGs under [kIconDebugDir]:
///     --dart-define=ICON_DEBUG_KEYS=prim1053,prim1151 --dart-define=ICON_DEBUG_DIR=<dir>
const String kIconDebugKeys = String.fromEnvironment('ICON_DEBUG_KEYS');
const String kIconDebugDir = String.fromEnvironment('ICON_DEBUG_DIR');

void _debugPng(String name, Uint8List rgba, int w, int h) {
  if (kIconDebugDir.isEmpty) return;
  final image = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      image.setPixelRgba(x, y, rgba[i], rgba[i + 1], rgba[i + 2], 255);
    }
  }
  File('$kIconDebugDir/$name.png')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
}

/// Stands in for a pixel the wire erosion erased: background for every geometric test,
/// unknown in every vote.
const int kErasedRgb = 0xFEFEFE;

/// How far, in pixels, a primitive's art sits from the centre of its node box on either axis
/// when it is centred: Not's negation bubble pulls its bounds one pixel left. To More
/// Specific Class draws its 32x16 art at the top of the box instead.
const int kPrimitiveArtMaxOffCentre = 2;

/// Whitens every ink of [rgba] ([w] by [h], node box inset by [pad]) that is not the icon.
/// Components form over [componentInk]: the icon is the component whose bounds hold the
/// box's centre (the largest when several do, or when none does) together with the
/// components inside its bounds and the non-wire-like components within two pixels of it
/// that keep the union centred in the box to within two pixels. Every other pixel of
/// [anyInk] farther than [kStrayInkReach] pixels from the kept components is whitened too,
/// so a neighbour's ink goes while the blended fringe and the wires against the icon stay.
void _keepMainCluster(
  Uint8List rgba,
  int w,
  int h,
  int pad,
  bool Function(Uint8List rgba, int w, int x, int y) componentInk,
  bool Function(Uint8List rgba, int w, int x, int y) anyInk,
) {
  final inky = componentInk;
  final compOf = List<int>.filled(w * h, -1);
  final comps = <({List<int> px, int l, int t, int r, int b})>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (compOf[y * w + x] != -1 || !inky(rgba, w, x, y)) continue;
      final id = comps.length;
      final pixels = <int>[];
      int cl = x, ct = y, cr = x, cb = y;
      final queue = <(int, int)>[(x, y)];
      while (queue.isNotEmpty) {
        final (px, py) = queue.removeLast();
        if (px < 0 || py < 0 || px >= w || py >= h) continue;
        final idx = py * w + px;
        if (compOf[idx] != -1 || !inky(rgba, w, px, py)) continue;
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
  if (comps.isEmpty) return;
  final cx = w ~/ 2, cy = h ~/ 2;
  var main = -1;
  for (var i = 0; i < comps.length; i++) {
    final c = comps[i];
    final holdsCentre = c.l <= cx && cx <= c.r && c.t <= cy && cy <= c.b;
    final mainHoldsCentre =
        main != -1 &&
        comps[main].l <= cx &&
        cx <= comps[main].r &&
        comps[main].t <= cy &&
        cy <= comps[main].b;
    if (main == -1 ||
        holdsCentre && !mainHoldsCentre ||
        holdsCentre == mainHoldsCentre && c.px.length > comps[main].px.length) {
      main = i;
    }
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
          c.l >= kl - 1 && c.r <= kr + 1 && c.t >= kt - 1 && c.b <= kb + 1;
      final adjacent =
          c.l - 2 <= kr && c.r + 2 >= kl && c.t - 2 <= kb && c.b + 2 >= kt;
      final wireLike = (c.b - c.t + 1) <= 3 || (c.r - c.l + 1) <= 1;
      final ul = c.l < kl ? c.l : kl, ur = c.r > kr ? c.r : kr;
      final ut = c.t < kt ? c.t : kt, ub = c.b > kb ? c.b : kb;
      final staysCentred =
          ((ul + ur) - 2 * cx).abs() <= 4 && ((ut + ub) - 2 * cy).abs() <= 4;
      if (inside || adjacent && !wireLike && staysCentred) {
        kept.add(i);
        kl = ul;
        kt = ut;
        kr = ur;
        kb = ub;
        grew = true;
      }
    }
  }
  final near = List<bool>.filled(w * h, false);
  for (final i in kept) {
    for (final idx in comps[i].px) {
      final x = idx % w, y = idx ~/ w;
      for (var dy = -kStrayInkReach; dy <= kStrayInkReach; dy++) {
        for (var dx = -kStrayInkReach; dx <= kStrayInkReach; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          near[ny * w + nx] = true;
        }
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (near[idx] || !anyInk(rgba, w, x, y)) continue;
      rgba[idx * 4] = rgba[idx * 4 + 1] = rgba[idx * 4 + 2] = 255;
    }
  }
}

/// How far, in pixels, ink may lie from the icon's cluster and still belong to the cut: the
/// blended fringe of an anti-aliased edge and the wire pixels against the icon.
const int kStrayInkReach = 2;

/// The reference renders' diagram dot grid, background rather than ink.
const int kDiagramGridDotRgb = 0xe2e2e2;

/// A primitive's icon is black ink on its yellow fill; in a hard-edged render every other
/// colour inside its node box is drawn over or beside it: wires, coercion dots, neighbours.
/// The primitives whose icons carry another colour are kept by hand.
const Set<int> kPrimitiveInkPalette = {0x000000, 0xFFFFCC};

/// Whether a hard-edged render's pixel of colour [rgb] is foreign to the icon of [key]: for
/// a primitive any colour outside [kPrimitiveInkPalette], otherwise wire ink or a coercion
/// dot. White is background, never foreign ink.
bool isForeignInk(String key, int rgb) =>
    rgb != 0xFFFFFF &&
    (key.startsWith('prim')
        ? !kPrimitiveInkPalette.contains(BdColorAlias.canonicalRgb(rgb))
        : isOverlayInk(rgb));

const Map<String, List<({String snippet, int oid})>> kTargetedIconSamples = {
  'prim1069': [(snippet: '34109337_OCxvL', oid: 599)],
  'prim1082': [(snippet: 'MD5', oid: 6017)],
  'prim1170': [(snippet: 'crc16', oid: 820), (snippet: 'crc16', oid: 619)],
  'prim1537': [(snippet: 'Excel_Cell_to_RowCol', oid: 477)],
  'prim2302': [
    (
      snippet: 'Error_1073807253_0xBFFF006B_at_VISA_Serial_Read_in_LabVIEW',
      oid: 273,
    ),
  ],
};

/// The asset key of [o]'s icon: its primitive's art key (an option variant when the node sets
/// one), or the class variant key of a single-op class in [primClasses]; null for other
/// objects.
String? iconReviewKeyOf(BdDiagram bd, BdObject o, Set<int> primClasses) {
  if (o.primitive?.primResId != null) return primIconName(primIconArtKeyOf(o)!);
  return primClasses.contains(o.kind)
      ? primIconName(bdClassVariantIconKey(bd, o))
      : null;
}

/// The background pixels kept around a node box in an extraction crop.
const int kPrimIconCropPad = 5;

/// The icon ink of one node-box crop ([pad] pixels around the box) on its own: [foreign]
/// colours whitened, the cluster holding the box centre kept, the rest transparent, cut to
/// the ink's bounds and clipped to the box when larger. `dx`, `dy` place the cut in the box.
({Uint8List rgba, int w, int h, int dx, int dy})? cleanNodeBoxCrop(
  Uint8List crop,
  int w,
  int h,
  int pad,
  bool Function(int rgb) foreign,
) {
  final boxWidth = w - 2 * pad, boxHeight = h - 2 * pad;
  if (boxWidth < 4 || boxHeight < 4) return null;
  final pixels = Uint8List.fromList(crop);
  for (var i = 0; i < pixels.length; i += 4) {
    final rgb = (pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2];
    if (foreign(rgb)) {
      pixels[i] = pixels[i + 1] = pixels[i + 2] = 255;
    }
  }
  bool inky(Uint8List rgba, int w, int x, int y) =>
      rgba[(y * w + x) * 4] < 240 ||
      rgba[(y * w + x) * 4 + 1] < 240 ||
      rgba[(y * w + x) * 4 + 2] < 240;
  _keepMainCluster(pixels, w, h, pad, inky, inky);
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
  if (right - left + 1 > boxWidth) {
    if (left < pad) left = pad;
    if (right > w - 1 - pad) right = w - 1 - pad;
  }
  if (bottom - top + 1 > boxHeight) {
    if (top < pad) top = pad;
    if (bottom > h - 1 - pad) bottom = h - 1 - pad;
  }
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

/// Whether a reference crop is a hard-edged render. For a primitive ([key] starting with
/// `prim`) every pixel inside the node box that is neither its ink ([kPrimitiveInkPalette])
/// nor overlay ink belongs to a component at most [kStrayInkMaxThickness] pixels thin that
/// reaches the box's edge, so is a wire crossing the box rather than a blended edge of the
/// icon or a tinted background; renders from LabVIEW
/// 2018 on smooth the icon's edges with a fixed ramp of greys that tile well, and only the
/// palette tells them apart. For any other key every colour inside the node box, overlay
/// ink and the white background aside, tiles at least [kHardEdgeMinRun] pixels;
/// anti-aliased renders blend the icon's edges into dozens of colours that occur once or
/// twice.
bool isHardEdgedCrop(Uint8List rgba, int w, int h, int pad, {String? key}) {
  final primitive = key?.startsWith('prim') ?? false;
  final counts = <int, int>{};
  final stray = List<bool>.filled(w * h, false);
  for (var y = pad; y < h - pad; y++) {
    for (var x = pad; x < w - pad; x++) {
      final i = (y * w + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (r >= 240 && g >= 240 && b >= 240) continue;
      final rgb = (r << 16) | (g << 8) | b;
      if (isOverlayInk(rgb)) continue;
      if (primitive) {
        if (!kPrimitiveInkPalette.contains(BdColorAlias.canonicalRgb(rgb))) {
          stray[y * w + x] = true;
        }
        continue;
      }
      counts[rgb] = (counts[rgb] ?? 0) + 1;
    }
  }
  if (!primitive) return counts.values.every((n) => n >= kHardEdgeMinRun);
  final seen = List<bool>.filled(w * h, false);
  for (var start = 0; start < w * h; start++) {
    if (!stray[start] || seen[start]) continue;
    var reachesEdge = false;
    var l = w, t = h, r = -1, b = -1;
    final queue = <int>[start];
    seen[start] = true;
    while (queue.isNotEmpty) {
      final idx = queue.removeLast();
      final x = idx % w, y = idx ~/ w;
      if (x <= pad || y <= pad || x >= w - 1 - pad || y >= h - 1 - pad) {
        reachesEdge = true;
      }
      if (x < l) l = x;
      if (x > r) r = x;
      if (y < t) t = y;
      if (y > b) b = y;
      for (final n in [idx - 1, idx + 1, idx - w, idx + w]) {
        if (n < 0 || n >= w * h || seen[n] || !stray[n]) continue;
        if ((n % w - x).abs() > 1) continue;
        seen[n] = true;
        queue.add(n);
      }
    }
    final thin =
        r - l + 1 <= kStrayInkMaxThickness ||
        b - t + 1 <= kStrayInkMaxThickness;
    if (!reachesEdge || !thin) return false;
  }
  return true;
}

/// The thickest a run of ink crossing a primitive's node box may be and still be a wire.
const int kStrayInkMaxThickness = 5;

/// The fewest pixels a colour must cover in a node box for the render to count as hard-edged.
const int kHardEdgeMinRun = 3;

/// Whether the node box of a reference crop holds icon ink at all: at least
/// [kIconInkMinPixels] pixels that are neither white nor overlay ink. A node the reference does not
/// show, such as one inside a frame the structure is not displaying, crops to a blank box.
bool hasIconInk(Uint8List rgba, int w, int h, int pad) {
  var ink = 0;
  for (var y = pad; y < h - pad; y++) {
    for (var x = pad; x < w - pad; x++) {
      final i = (y * w + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (r >= 240 && g >= 240 && b >= 240) continue;
      if (isOverlayInk((r << 16) | (g << 8) | b)) continue;
      if (++ink >= kIconInkMinPixels) return true;
    }
  }
  return false;
}

const int kIconInkMinPixels = 16;

class PrimIconExtraction {
  const PrimIconExtraction({
    required this.appDir,
    required this.assetDir,
    required this.pending,
    required this.failed,
    required this.observedKeys,
    required this.skippedLowQuality,
    required this.lowRegistrationOnly,
    required this.antiAliased,
    required this.softOnly,
    required this.watermarkedSnippets,
    required this.watermarkedOnlyKeys,
    required this.inferredBorders,
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

  /// Keys cut from the renders of [skippedLowQuality] snippets because no other snippet shows
  /// them.
  final Set<String> lowRegistrationOnly;

  /// Per key, the snippets whose render of it was anti-aliased and therefore set aside.
  final Map<String, Set<String>> antiAliased;

  /// Keys cut from anti-aliased renders because no hard-edged render of them exists.
  final Set<String> softOnly;

  /// Snippets whose saving LabVIEW watermarks its renders, see [ViSaveRecord.rendersWatermark];
  /// nothing is harvested from them.
  final List<String> watermarkedSnippets;

  /// Keys seen only in [watermarkedSnippets], so with no render to cut from.
  final Set<String> watermarkedOnlyKeys;

  /// Per key cut from anti-aliased renders, how its border was replaced by the canonical
  /// border of the hard-edged icons that share its silhouette, see [inferIconBorders].
  final Map<String, String> inferredBorders;

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
  final lowRegistration =
      <
        String,
        List<({Uint8List rgba, int w, int h, String source, double quality})>
      >{};
  final lowRegistrationSoft =
      <
        String,
        List<({Uint8List rgba, int w, int h, String source, double quality})>
      >{};
  final observedKeys = <String>{};
  final soft =
      <
        String,
        List<({Uint8List rgba, int w, int h, String source, double quality})>
      >{};
  final antiAliased = <String, Set<String>>{};
  final targeted =
      <
        String,
        List<({Uint8List rgba, int w, int h, int pad, String source})>
      >{};
  final versionOfSnippet = <String, int>{};
  final watermarkedSnippets = <String>[];
  final watermarkedKeys = <String>{};
  await tester.runAsync(() async {
    for (final f in pngs) {
      final vi = extractSnippetVi(f.readAsBytesSync());
      if (vi == null) continue;
      final model = buildViModel(vi);
      final bd = bestBlockDiagram(model);
      if (bd == null) continue;
      if (model.saveRecord?.rendersWatermark ?? false) {
        watermarkedSnippets.add(f.uri.pathSegments.last.replaceAll('.png', ''));
        for (final o in bdDrawableObjects(bd)) {
          final key = iconReviewKeyOf(bd, o, primClasses);
          if (key != null) watermarkedKeys.add(key);
        }
        continue;
      }
      final drawable = bdDrawableObjects(bd);
      final raster = await rasteriseBlockDiagram(
        bd,
        primIcons: loadPrimIcons(),
        scale: 1.0,
        margin: 2,
        wires: bdVisibleWires(bd),
        drawable: drawable,
      );
      if (raster == null) continue;
      final reference = await decodeReferenceImage(f.readAsBytesSync());
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
      const pad = kPrimIconCropPad;
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
        if (left + w <= pad ||
            top + h <= pad ||
            left >= refW - pad ||
            top >= refH - pad) {
          return null;
        }
        final crop = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
        for (var y = 0; y < h; y++) {
          final sy = top + y;
          if (sy < 0 || sy >= refH) continue;
          final x0 = left < 0 ? -left : 0,
              x1 = left + w > refW ? refW - left : w;
          if (x1 <= x0) continue;
          crop.setRange(
            (y * w + x0) * 4,
            (y * w + x1) * 4,
            result.referenceRgba,
            (sy * refW + left + x0) * 4,
          );
        }
        for (var i = 0; i < crop.length; i += 4) {
          final rgb = (crop[i] << 16) | (crop[i + 1] << 8) | crop[i + 2];
          if (rgb == kDiagramGridDotRgb) {
            crop[i] = crop[i + 1] = crop[i + 2] = 255;
            continue;
          }
          final canonical = BdColorAlias.canonicalRgb(rgb);
          if (canonical != rgb) {
            crop[i] = canonical >> 16;
            crop[i + 1] = (canonical >> 8) & 0xff;
            crop[i + 2] = canonical & 0xff;
          }
        }
        return (rgba: crop, w: w, h: h);
      }

      for (final o in drawable) {
        final b = o.absBounds;
        final key = iconReviewKeyOf(bd, o, primClasses);
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
        final crop = cropOf(b);
        if (crop == null || !hasIconInk(crop.rgba, crop.w, crop.h, pad)) {
          continue;
        }
        final hard = isHardEdgedCrop(crop.rgba, crop.w, crop.h, pad, key: key);
        final bucket = lowQuality
            ? hard
                  ? lowRegistration
                  : lowRegistrationSoft
            : hard
            ? samples
            : soft;
        if (!hard) (antiAliased[key] ??= {}).add(name);
        if ((bucket[key]
                    ?.where((s) => versionOfSnippet[s.source] == major)
                    .length ??
                0) >=
            8) {
          continue;
        }
        (bucket[key] ??= []).add((
          rgba: crop.rgba,
          w: crop.w,
          h: crop.h,
          source: name,
          quality: quality,
        ));
      }
    }
  });

  final lowRegistrationOnly = <String>{};
  for (final key in {...lowRegistration.keys, ...lowRegistrationSoft.keys}) {
    if (samples.containsKey(key) || soft.containsKey(key)) continue;
    lowRegistrationOnly.add(key);
    if (lowRegistration[key] case final hard?) samples[key] = hard;
    if (lowRegistrationSoft[key] case final aa?) soft[key] = aa;
  }

  final softOnly = <String>{};
  for (final entry in soft.entries) {
    if (samples.containsKey(entry.key)) continue;
    samples[entry.key] = entry.value;
    softOnly.add(entry.key);
  }

  bool inky(Uint8List rgba, int w, int x, int y) {
    final i = (y * w + x) * 4;
    return rgba[i] < 240 || rgba[i + 1] < 240 || rgba[i + 2] < 240;
  }

  bool Function(int rgb) foreignRgb = isOverlayInk;
  bool foreign(Uint8List rgba, int w, int x, int y) {
    final i = (y * w + x) * 4;
    return inky(rgba, w, x, y) &&
        foreignRgb((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }

  bool Function(int rgb) erodableRgb = isOverlayInk;
  bool erodable(Uint8List rgba, int w, int x, int y) {
    final i = (y * w + x) * 4;
    return inky(rgba, w, x, y) &&
        erodableRgb((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }

  bool iconInk(Uint8List rgba, int w, int x, int y) =>
      inky(rgba, w, x, y) && !foreign(rgba, w, x, y);

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

  /// Makes transparent every foreign pixel of [icon] that touches a transparent pixel or
  /// the edge, repeatedly, so wire ink left against the icon's outline falls away, then
  /// trims the transparent margin.
  img.Image peelForeign(img.Image icon) {
    final iw = icon.width, ih = icon.height;
    var peeled = true;
    while (peeled) {
      peeled = false;
      for (final p in icon) {
        if (p.a == 0 || !foreignRgb(_rgbOf(p))) continue;
        final x = p.x, y = p.y;
        final outside =
            x == 0 ||
            y == 0 ||
            x == iw - 1 ||
            y == ih - 1 ||
            icon.getPixel(x - 1, y).a == 0 ||
            icon.getPixel(x + 1, y).a == 0 ||
            icon.getPixel(x, y - 1).a == 0 ||
            icon.getPixel(x, y + 1).a == 0;
        if (!outside) continue;
        icon.setPixelRgba(x, y, 0, 0, 0, 0);
        peeled = true;
      }
    }
    var l = iw, t = ih, r = -1, b = -1;
    for (final p in icon) {
      if (p.a == 0) continue;
      if (p.x < l) l = p.x;
      if (p.x > r) r = p.x;
      if (p.y < t) t = p.y;
      if (p.y > b) b = p.y;
    }
    if (r < 0 || (l == 0 && t == 0 && r == iw - 1 && b == ih - 1)) return icon;
    return img.copyCrop(icon, x: l, y: t, width: r - l + 1, height: b - t + 1);
  }

  void erodeWireTails(Uint8List rgba, int w, int h) {
    int vrun(int x, int y) {
      var t = y, b = y;
      while (t > 0 && erodable(rgba, w, x, t - 1)) {
        t--;
      }
      while (b < h - 1 && erodable(rgba, w, x, b + 1)) {
        b++;
      }
      return b - t + 1;
    }

    int hrun(int x, int y) {
      var l = x, r = x;
      while (l > 0 && erodable(rgba, w, l - 1, y)) {
        l--;
      }
      while (r < w - 1 && erodable(rgba, w, r + 1, y)) {
        r++;
      }
      return r - l + 1;
    }

    final queue = <(int, int, bool)>[];
    for (var y = 0; y < h; y++) {
      for (final x in [0, w - 1]) {
        if (erodable(rgba, w, x, y) && vrun(x, y) <= 5) queue.add((x, y, true));
      }
    }
    for (var x = 0; x < w; x++) {
      for (final y in [0, h - 1]) {
        if (erodable(rgba, w, x, y) && hrun(x, y) <= 5)
          queue.add((x, y, false));
      }
    }
    while (queue.isNotEmpty) {
      final (x, y, horiz) = queue.removeLast();
      if (x < 0 || y < 0 || x >= w || y >= h) continue;
      if (!erodable(rgba, w, x, y)) continue;
      if (horiz ? vrun(x, y) > 5 : hrun(x, y) > 5) continue;
      final i = (y * w + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = kErasedRgb & 0xff;
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
      final identity = key.split('@').first;
      final antiAliased = softOnly.contains(identity);
      final primitive = identity.startsWith('prim');
      foreignRgb = antiAliased
          ? isOverlayInk
          : (rgb) => isForeignInk(identity, rgb);
      erodableRgb = primitive && !antiAliased
          ? (rgb) => isForeignInk(identity, rgb)
          : isOverlayInk;
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

      const boxPad = kPrimIconCropPad;
      final bw = w0 - 2 * boxPad, bh = h0 - 2 * boxPad;
      bool ringInk(Uint8List rgba, int x, int y) =>
          iconInk(rgba, w0, x, y) ||
          primitive && !antiAliased && foreign(rgba, w0, x, y);
      bool ringComplete(Uint8List rgba) {
        if (bw < 8 || bh < 8) return false;
        for (var x = boxPad; x < boxPad + bw; x++) {
          if (!ringInk(rgba, x, boxPad) || !ringInk(rgba, x, boxPad + bh - 1)) {
            return false;
          }
        }
        for (var y = boxPad; y < boxPad + bh; y++) {
          if (!ringInk(rgba, boxPad, y) || !ringInk(rgba, boxPad + bw - 1, y)) {
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
        final icon = img.Image(width: bw, height: bh, numChannels: 4);
        var disputed = 0;
        for (var y = 0; y < bh; y++) {
          for (var x = 0; x < bw; x++) {
            final i = (y * bw + x) * 4;
            final own = <int, int>{}, over = <int, int>{};
            for (final c in ringed) {
              final rgb =
                  (c.rect[i] << 16) | (c.rect[i + 1] << 8) | c.rect[i + 2];
              if (rgb == kErasedRgb) continue;
              final tally = foreignRgb(rgb) ? over : own;
              tally[rgb] = (tally[rgb] ?? 0) + 1;
            }
            final tally = own.isNotEmpty ? own : over;
            if (tally.length > 1) disputed++;
            var rgb = 0, best = 0;
            for (final e in tally.entries) {
              if (e.value > best) {
                best = e.value;
                rgb = e.key;
              }
            }
            icon.setPixelRgba(
              x,
              y,
              rgb >> 16,
              (rgb >> 8) & 0xff,
              rgb & 0xff,
              255,
            );
          }
        }
        included[key] = {for (final c in ringed) c.source};
        pending[key] = (
          icon: icon,
          sources:
              'border-exact rect (${ringed.length} ring sample'
              '${ringed.length == 1 ? '' : 's'} voted per pixel, foreign ink '
              'outvoted by the icon beneath'
              '${disputed == 0 ? '' : ', $disputed pixels disputed'}): '
              '${included[key]!.join(', ')}',
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
        for (var y = boxPad; y < boxPad + bh; y++) {
          for (var x = boxPad; x < boxPad + bw; x++) {
            final sx = x + bx, sy = y + by;
            final aInk = iconInk(a.rgba, w0, x, y);
            final bInk =
                sx >= 0 &&
                sy >= 0 &&
                sx < b.w &&
                sy < b.h &&
                iconInk(b.rgba, b.w, sx, sy);
            if (!aInk && !bInk) continue;
            union++;
            if (aInk && bInk) match++;
          }
        }
        return (bx, by, union == 0 ? 0 : match / union);
      }

      /// The share of inked pixels of [a] and [b] (aligned by [dx], [dy]) that are the same
      /// colour; foreign ink in either is left out.
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
            if (ca == kErasedRgb || cb == kErasedRgb) continue;
            if (foreignRgb(ca) || foreignRgb(cb)) continue;
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
      final debug = kIconDebugKeys.split(',').contains(identity);
      if (debug) {
        var n = 0;
        for (final s in group) {
          final tag = aligned.any((a) => a.source == s.source) ? 'in' : 'out';
          _debugPng('$key/sample${n++}_${tag}_${s.source}', s.rgba, s.w, s.h);
        }
        File('$kIconDebugDir/$key/notes.txt')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            'seeded: $seeded base: ${base.source}\n'
            '${group.map((s) {
              final (dx, dy, agree) = alignOnto(base, s);
              return '${s.source}: dx $dx dy $dy agree ${agree.toStringAsFixed(3)} '
                  'sameArt ${sameArtRate(base, s, dx, dy).toStringAsFixed(3)}';
            }).join('\n')}\n',
          );
      }
      final consensus = Uint8List(w0 * h0 * 4);
      for (var y = 0; y < h0; y++) {
        for (var x = 0; x < w0; x++) {
          final own = <int, int>{}, over = <int, int>{};
          var ownVotes = 0, overVotes = 0;
          for (final a in aligned) {
            final sx = x + a.dx, sy = y + a.dy;
            if (sx < 0 || sy < 0 || sx >= a.w || sy >= a.h) continue;
            final j = (sy * a.w + sx) * 4;
            final q =
                ((a.rgba[j] >> 4) << 8) |
                ((a.rgba[j + 1] >> 4) << 4) |
                (a.rgba[j + 2] >> 4);
            final rgb =
                (a.rgba[j] << 16) | (a.rgba[j + 1] << 8) | a.rgba[j + 2];
            if (rgb == kErasedRgb) continue;
            if (foreignRgb(rgb)) {
              over[q] = (over[q] ?? 0) + 1;
              overVotes++;
            } else {
              own[q] = (own[q] ?? 0) + 1;
              ownVotes++;
            }
          }
          final i = (y * w0 + x) * 4;
          if (ownVotes + overVotes == 0) {
            consensus[i] = consensus[i + 1] = consensus[i + 2] = 255;
            consensus[i + 3] = 255;
            continue;
          }
          final foreignCounts = ownVotes < 2 && overVotes > 0;
          final counted = foreignCounts ? ownVotes + overVotes : ownVotes;
          final votes = {...own};
          if (foreignCounts) {
            for (final e in over.entries) {
              votes[e.key] = (votes[e.key] ?? 0) + e.value;
            }
          }
          final top =
              (votes.entries.toList()..sort((a, b) => b.value - a.value)).first;
          if (counted >= 3 && top.value * 3 < counted * 2) {
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
      bool paletteInk(Uint8List rgba, int w, int x, int y) {
        final i = (y * w + x) * 4;
        return inky(rgba, w, x, y) &&
            kPrimitiveInkPalette.contains(
              BdColorAlias.canonicalRgb(
                (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2],
              ),
            );
      }

      void keepMainCluster(Uint8List rgba) => _keepMainCluster(
        rgba,
        w0,
        h0,
        boxPad,
        primitive ? paletteInk : iconInk,
        inky,
      );

      if (debug) _debugPng('$key/consensus_voted', consensus, w0, h0);
      keepMainCluster(consensus);
      if (debug) _debugPng('$key/consensus_clustered', consensus, w0, h0);
      int l = w0, t = h0, r = -1, btm = -1;

      /// The ink's bounds; foreign ink lying on the boundary is a stub and is erased, so
      /// the bounds shrink until no boundary pixel is foreign.
      void measure(Uint8List rgba) {
        while (true) {
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
          if (r < 0) return;
          var erased = false;
          for (var y = t; y <= btm; y++) {
            for (var x = l; x <= r; x++) {
              if (y != t && y != btm && x != l && x != r) continue;
              if (!foreign(rgba, w0, x, y)) continue;
              final i = (y * w0 + x) * 4;
              rgba[i] = rgba[i + 1] = rgba[i + 2] = 255;
              erased = true;
            }
          }
          if (!erased) return;
        }
      }

      /// Whether ink bounds sit within [kPrimitiveArtMaxOffCentre] pixels of the node box's
      /// centre on both axes, as most primitives' art does; a single sample that is wins over
      /// one that is not, since a neighbour fused to the icon pulls the bounds off centre.
      bool centredInBox(int l, int t, int r, int b) =>
          ((l + r) - (w0 - 1)).abs() <= 2 * kPrimitiveArtMaxOffCentre &&
          ((t + b) - (h0 - 1)).abs() <= 2 * kPrimitiveArtMaxOffCentre;

      String? singleSource;
      Uint8List? centredSingle() {
        var bestInk = 0, bestCentred = false;
        Uint8List? single;
        for (final s in group) {
          final copy = Uint8List.fromList(s.rgba);
          keepMainCluster(copy);
          measure(copy);
          if (debug) {
            _debugPng('$key/single_${s.source}', copy, w0, h0);
            File('$kIconDebugDir/$key/notes.txt').writeAsStringSync(
              'single ${s.source}: l $l t $t r $r b $btm\n',
              mode: FileMode.append,
            );
          }
          if (r < 0) continue;
          if (l == 0 || t == 0 || r == w0 - 1 || btm == h0 - 1) continue;
          final cx = w0 ~/ 2, cy = h0 ~/ 2;
          if (l > cx || r < cx || t > cy || btm < cy) continue;
          final centred = !primitive || centredInBox(l, t, r, btm);
          if (r - l + 1 > w0 - 4 || btm - t + 1 > h0 - 4) continue;
          var ink = 0;
          for (var y = t; y <= btm; y++) {
            for (var x = l; x <= r; x++) {
              if (inky(copy, w0, x, y)) ink++;
            }
          }
          if (ink < 60) continue;
          if (centred && !bestCentred ||
              centred == bestCentred && ink > bestInk) {
            bestInk = ink;
            bestCentred = centred;
            single = copy;
            singleSource = s.source;
          }
        }
        return single;
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
      if (r - l + 1 > bw) {
        if (l < boxPad) l = boxPad;
        if (r > w0 - 1 - boxPad) r = w0 - 1 - boxPad;
      }
      if (btm - t + 1 > bh) {
        if (t < boxPad) t = boxPad;
        if (btm > h0 - 1 - boxPad) btm = h0 - 1 - boxPad;
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
      final maxW = w0 - 2 * boxPad + 6, maxH = h0 - 2 * boxPad + 6;
      var finalIcon = peelForeign(icon);
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
            rebuilt = peelForeign(rebuilt);
            method = 'single-sample retry after oversized consensus';
          }
        }
        if (rebuilt == null) {
          failed[key] =
              'extracted ink ${finalIcon.width}x${finalIcon.height} exceeds '
              'the node box (${w0 - 2 * boxPad}x${h0 - 2 * boxPad}) — displaced model bounds '
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
    if (added) continue;
    var retried = false;
    for (final key in failed.keys.toList()) {
      final fallback = soft[key];
      if (fallback == null || softOnly.contains(key)) continue;
      samples[key] = fallback;
      failed.remove(key);
      softOnly.add(key);
      retried = true;
    }
    if (!retried) break;
  }

  final inferredBorders = inferIconBorders(
    pending: pending,
    softOnly: softOnly,
    assetDir: assetDir,
  );

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
        if (cleanNodeBoxCrop(
              crop.rgba,
              crop.w,
              crop.h,
              crop.pad,
              (rgb) => isForeignInk(key, rgb),
            )
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
    watermarkedSnippets: watermarkedSnippets,
    watermarkedOnlyKeys: watermarkedKeys.difference(observedKeys),
    skippedLowQuality: skippedLowQuality,
    lowRegistrationOnly: lowRegistrationOnly,
    antiAliased: antiAliased,
    softOnly: softOnly,
    inferredBorders: inferredBorders,
    palette: paletteList,
    verifiedKeys: verifiedKeys,
    handKeys: handKeys,
    renamed: renamed,
  );
}

/// Folds the appearances of each key (`key`, `key@1`, …: samples that did not agree with
/// an earlier cut, from other LabVIEW majors) into generations named `key_from<major>` by
/// the first LabVIEW major each appearance comes from. A verified key's committed asset
/// names the generation it equals; when one cut serves every major, a verified generation
/// it equals folds back into the plain key. Appearances whose cuts are identical are one
/// candidate. A primitive has one art unless verified generations of it exist, so its
/// appearances never split: the cut most samples agree on serves it and the others are set
/// aside.
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
    final candidates = <String>[];
    for (final k in members) {
      if (pending[k] == null || (included[k]?.length ?? 0) < 2) continue;
      String? twin;
      for (final c in candidates) {
        if (_sameArt(pending[c]!.icon, pending[k]!.icon, tolerance: 0)) {
          twin = c;
          break;
        }
      }
      if (twin == null) {
        candidates.add(k);
      } else {
        included[twin]!.addAll(included[k]!);
        included[k] = {};
      }
    }
    if (base.startsWith('prim')) {
      final defects = {
        for (final k in candidates) k: _primDefects(pending[k]!.icon),
      };
      candidates.sort(
        (a, b) => defects[a]! != defects[b]!
            ? defects[a]!.compareTo(defects[b]!)
            : included[b]!.length.compareTo(included[a]!.length),
      );
    }
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
    final primitive =
        base.startsWith('prim') &&
        !verifiedKeys.any((k) => k.startsWith('${base}_from'));
    final split =
        !primitive &&
        runs.map((r) => r.key).toSet().length >= 2 &&
        (committed == null ||
            runs.any(
              (r) => _sameArt(pending[r.key]!.icon, committed, tolerance: 0),
            ));
    String? agreeingWithCommitted;
    if (primitive && committed != null) {
      for (final k in candidates) {
        if (_sameArt(pending[k]!.icon, committed, tolerance: 0)) {
          agreeingWithCommitted = k;
          break;
        }
      }
    }
    final keep = split
        ? null
        : primitive
        ? agreeingWithCommitted ?? candidates.firstOrNull ?? base
        : committed != null
        ? base
        : candidates.firstOrNull ?? base;
    if (!split) {
      var cut = pending[keep!];
      final inc = included[keep];
      if (primitive && cut != null) {
        final aside = members
            .where((k) => k != keep)
            .fold(0, (n, k) => n + (included[k]?.length ?? 0));
        if (aside > 0) {
          cut = (
            icon: cut.icon,
            sources:
                '${cut.sources}; $aside disagreeing sample'
                '${aside == 1 ? '' : 's'} set aside',
          );
        }
      }
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
        for (final generation in verifiedKeys) {
          if (!generation.startsWith('${base}_from')) continue;
          final art = _committedAsset(assetDir, generation);
          if (art != null && _sameArt(cut.icon, art, tolerance: 0)) {
            renamed[generation] = base;
          }
        }
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

/// The pixels of a primitive's cut that cannot be its art: opaque pixels outside
/// [kPrimitiveInkPalette] and transparent pixels enclosed by the art (a hole where a wire or
/// coercion dot hid the icon in every sample).
int _primDefects(img.Image icon) {
  final w = icon.width, h = icon.height;
  final outside = List<bool>.filled(w * h, false);
  final stack = <int>[];
  for (var x = 0; x < w; x++) {
    stack.addAll([x, (h - 1) * w + x]);
  }
  for (var y = 0; y < h; y++) {
    stack.addAll([y * w, y * w + w - 1]);
  }
  while (stack.isNotEmpty) {
    final idx = stack.removeLast();
    if (outside[idx] || icon.getPixel(idx % w, idx ~/ w).a != 0) continue;
    outside[idx] = true;
    final x = idx % w, y = idx ~/ w;
    if (x > 0) stack.add(idx - 1);
    if (x < w - 1) stack.add(idx + 1);
    if (y > 0) stack.add(idx - w);
    if (y < h - 1) stack.add(idx + w);
  }
  var defects = 0;
  for (final p in icon) {
    if (p.a == 0) {
      if (!outside[p.y * w + p.x]) defects++;
    } else if (!kPrimitiveInkPalette.contains(
      BdColorAlias.canonicalRgb(_rgbOf(p)),
    )) {
      defects++;
    }
  }
  return defects;
}

/// Whether two cuts are the same art: the same size and at most [tolerance] pixels that
/// differ in colour once aliased or in transparency.
bool _sameArt(img.Image a, img.Image b, {int tolerance = 12}) {
  if (a.width != b.width || a.height != b.height) return false;
  var diffs = 0;
  for (final px in a) {
    final q = b.getPixel(px.x, px.y);
    if (px.a != q.a || !BdColorAlias.sameColor(_rgbOf(px), _rgbOf(q))) diffs++;
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
      if (px.a != cp.a || !BdColorAlias.sameColor(_rgbOf(px), _rgbOf(cp))) {
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

int _rgbOf(img.Pixel p) =>
    (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();

/// A silhouette the hard-edged assets share: its size and opaque mask, the positions of its
/// border pixels, and each distinct colouring of that border with the keys that carry it.
class _IconShape {
  _IconShape(this.width, this.height, this.mask, this.border);

  final int width;
  final int height;
  final Uint8List mask;
  final List<int> border;
  final Map<String, List<String>> rings = {};
  final Map<String, img.Image> carriers = {};
  int get area => mask.fold(0, (sum, v) => sum + v);
}

/// The least share of a hard-edged shape's opaque pixels an anti-aliased cut must cover for
/// the shape to be its outline.
const double kInferredBorderMinCoverage = 0.97;

/// How far, in pixels, an anti-aliased cut may reach beyond the shape it is matched to:
/// the blended fringe LabVIEW draws outside an icon's edge.
const int kInferredBorderFringe = 2;

/// Rebuilds every icon in [softOnly] (cut from anti-aliased renders, so its outline is
/// blended with the background) on the silhouette of the hard-edged assets in [assetDir]:
/// the shape, up to [kInferredBorderFringe] pixels smaller than the cut in each direction,
/// that the cut covers by at least [kInferredBorderMinCoverage] while reaching no further than
/// the fringe beyond it; among such shapes the one covered best, then the largest. The
/// border colouring is the one, among the shape's carriers, nearest the cut's own border
/// pixels. A primitive keeps every cut pixel in [kPrimitiveInkPalette] and takes every other
/// pixel from that carrier, since the renders blend only the edges; any other key keeps the
/// cut's interior and takes the border. Returns a note per key rebuilt; a key without a
/// matching shape keeps its cut and gets no note.
Map<String, String> inferIconBorders({
  required Map<String, ({img.Image icon, String sources})> pending,
  required Set<String> softOnly,
  required Directory assetDir,
}) {
  String keyOf(File f) => f.uri.pathSegments.last
      .replaceFirst(RegExp(r'\.png$'), '')
      .replaceFirst(
        RegExp(r'_(?!t\d|r[0-9a-f]+(?:_|$)|from\d)[a-z0-9-]+$'),
        '',
      );
  final shapes = <String, _IconShape>{};
  for (final f in assetDir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.png')) continue;
    final key = keyOf(f);
    if (softOnly.contains(key.replaceFirst(RegExp(r'_from\d+$'), ''))) continue;
    final image = img.decodePng(f.readAsBytesSync());
    if (image == null) continue;
    final w = image.width, h = image.height;
    final alpha = Uint8List(w * h);
    for (final px in image) {
      alpha[px.y * w + px.x] = px.a == 0 ? 0 : 1;
    }
    final border = primIconBorderMask(alpha, w, h);
    final positions = [
      for (var i = 0; i < border.length; i++)
        if (border[i] != 0) i,
    ];
    final id = '${w}x$h:${String.fromCharCodes(alpha.map((v) => v + 0x30))}';
    final shape = shapes[id] ??= _IconShape(w, h, alpha, positions);
    final ring = positions
        .map(
          (i) => BdColorAlias.canonicalRgb(
            _rgbOf(image.getPixel(i % w, i ~/ w)),
          ).toRadixString(16).padLeft(6, '0'),
        )
        .join(',');
    (shape.rings[ring] ??= []).add(key);
    shape.carriers[ring] ??= image;
  }
  final notes = <String, String>{};
  for (final key in softOnly) {
    final cut = pending[key];
    if (cut == null) continue;
    final icon = cut.icon;
    if (kIconDebugDir.isNotEmpty && kIconDebugKeys.split(',').contains(key)) {
      File('$kIconDebugDir/$key/cut_before_inference.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(icon));
    }
    final w = icon.width, h = icon.height;
    final soft = Uint8List(w * h);
    for (final px in icon) {
      if (px.a == 0) continue;
      soft[px.y * w + px.x] = 1;
    }
    _IconShape? best;
    var bestCoverage = 0.0, bestDx = 0, bestDy = 0;
    for (final shape in shapes.values) {
      if (shape.width > w || shape.height > h) continue;
      if (w - shape.width > 2 * kInferredBorderFringe ||
          h - shape.height > 2 * kInferredBorderFringe) {
        continue;
      }
      for (var dy = 0; dy <= h - shape.height; dy++) {
        for (var dx = 0; dx <= w - shape.width; dx++) {
          var covered = 0;
          for (var y = 0; y < shape.height; y++) {
            for (var x = 0; x < shape.width; x++) {
              if (shape.mask[y * shape.width + x] != 0 &&
                  soft[(y + dy) * w + x + dx] != 0) {
                covered++;
              }
            }
          }
          final coverage = covered / shape.area;
          if (coverage < kInferredBorderMinCoverage) continue;
          var withinFringe = true;
          for (var y = 0; y < h && withinFringe; y++) {
            for (var x = 0; x < w && withinFringe; x++) {
              if (soft[y * w + x] == 0) continue;
              var near = false;
              for (
                var fy = -kInferredBorderFringe;
                fy <= kInferredBorderFringe && !near;
                fy++
              ) {
                for (
                  var fx = -kInferredBorderFringe;
                  fx <= kInferredBorderFringe && !near;
                  fx++
                ) {
                  final sx = x + fx - dx, sy = y + fy - dy;
                  if (sx < 0 ||
                      sy < 0 ||
                      sx >= shape.width ||
                      sy >= shape.height) {
                    continue;
                  }
                  near = shape.mask[sy * shape.width + sx] != 0;
                }
              }
              if (!near) withinFringe = false;
            }
          }
          if (!withinFringe) continue;
          if (coverage > bestCoverage ||
              coverage == bestCoverage && shape.area > best!.area) {
            bestCoverage = coverage;
            best = shape;
            bestDx = dx;
            bestDy = dy;
          }
        }
      }
    }
    if (best == null) continue;
    final shape = best;
    String? chosenRing;
    var chosenDistance = 1 << 40;
    for (final ring in shape.rings.keys) {
      final colours = ring.split(',');
      var distance = 0;
      for (var n = 0; n < shape.border.length; n++) {
        final i = shape.border[n];
        final x = i % shape.width + bestDx, y = i ~/ shape.width + bestDy;
        final px = icon.getPixel(x, y);
        final rgb = int.parse(colours[n], radix: 16);
        distance +=
            (px.r.toInt() - (rgb >> 16)).abs() +
            (px.g.toInt() - ((rgb >> 8) & 0xff)).abs() +
            (px.b.toInt() - (rgb & 0xff)).abs();
      }
      final support = shape.rings[ring]!.length;
      if (distance < chosenDistance ||
          distance == chosenDistance &&
              support > shape.rings[chosenRing]!.length) {
        chosenDistance = distance;
        chosenRing = ring;
      }
    }
    final colours = chosenRing!.split(',');
    final carrier = shape.carriers[chosenRing]!;
    final primitive = key.startsWith('prim');
    final rebuilt = img.Image(
      width: shape.width,
      height: shape.height,
      numChannels: 4,
    );
    var fromCarrier = 0;
    for (var y = 0; y < shape.height; y++) {
      for (var x = 0; x < shape.width; x++) {
        if (shape.mask[y * shape.width + x] == 0) continue;
        final px = icon.getPixel(x + bestDx, y + bestDy);
        var rgb = px.a == 0 ? 0xFFFFFF : BdColorAlias.canonicalRgb(_rgbOf(px));
        if (primitive && !kPrimitiveInkPalette.contains(rgb)) {
          rgb = _rgbOf(carrier.getPixel(x, y));
          fromCarrier++;
        }
        rebuilt.setPixelRgba(
          x,
          y,
          rgb >> 16,
          (rgb >> 8) & 0xff,
          rgb & 0xff,
          255,
        );
      }
    }
    if (!primitive) {
      for (var n = 0; n < shape.border.length; n++) {
        final i = shape.border[n];
        final rgb = int.parse(colours[n], radix: 16);
        rebuilt.setPixelRgba(
          i % shape.width,
          i ~/ shape.width,
          rgb >> 16,
          (rgb >> 8) & 0xff,
          rgb & 0xff,
          255,
        );
      }
    }
    final carriers = shape.rings[chosenRing]!;
    final sharing = shape.rings.values.fold(
      0,
      (sum, keys) => sum + keys.length,
    );
    pending[key] = (icon: rebuilt, sources: cut.sources);
    notes[key] =
        'outline inferred: the ${shape.width}x${shape.height} silhouette of '
        '$sharing hard-edged icon${sharing == 1 ? '' : 's'} is covered by the cut at '
        '${(bestCoverage * 100).toStringAsFixed(1)}%; '
        '${primitive ? '$fromCarrier blended pixels taken from' : 'its border coloured as'} '
        '${carriers.first}${carriers.length > 1 ? ' and ${carriers.length - 1} more' : ''}';
  }
  return notes;
}
