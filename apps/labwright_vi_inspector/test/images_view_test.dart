import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/image_clipboard.dart';
import 'package:labwright_vi_inspector/src/images_view.dart';
import 'package:labwright_vi_inspector/src/mac_icon_palette.dart';
import 'package:labwright_vi_inspector/src/span_annotations.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

/// Records the PNGs written to it so a copy action can be verified without a real
/// system clipboard (which isn't available on the test VM).
class _FakeImageClipboard implements ImageClipboard {
  final List<Uint8List> writes = [];
  bool result = true;

  @override
  Future<bool> copyPng(Uint8List pngBytes) async {
    writes.add(pngBytes);
    return result;
  }
}

/// The corpus root, or null when it is not fetched (corpus-guarded tests skip).
Directory? _corpusDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
      '${dir.path}/packages/labwright_rsrc_parse/corpus/vi',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

ViLegacyIcon _icon(int fill, int bpp) => decodeLegacyIcon(
  Uint8List.fromList(
    List<int>.filled(bpp == 8 ? 1024 : (bpp == 4 ? 512 : 128), fill),
  ),
  bpp,
)!;

/// Renders a [LegacyIconPainter] to a raw RGBA buffer with each 32×32 icon pixel
/// scaled to a [cell]×[cell] block, so a cell centre can be sampled clear of the
/// 1px grid-border stroke. Returns the buffer and its row stride (in pixels).
Future<({Uint8List rgba, int stride})> _renderIcon(
  WidgetTester tester,
  ViLegacyIcon icon, {
  int cell = 8,
}) async {
  const dim = 32;
  final side = (dim * cell).toDouble();
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: CustomPaint(
              size: Size(side, side),
              painter: LegacyIconPainter(icon),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  late Uint8List rgba;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(); // pixelRatio 1.0 → side×side px
    final data = await image.toByteData(); // rawRgba
    rgba = data!.buffer.asUint8List();
  });
  return (rgba: rgba, stride: dim * cell);
}

/// The colour at the centre of icon cell ([cx], [cy]) in a [_renderIcon] buffer.
Color _cellColor(
  ({Uint8List rgba, int stride}) render,
  int cx,
  int cy, {
  int cell = 8,
}) {
  final px = cx * cell + cell ~/ 2, py = cy * cell + cell ~/ 2;
  final i = (py * render.stride + px) * 4;
  return Color.fromARGB(
    render.rgba[i + 3],
    render.rgba[i],
    render.rgba[i + 1],
    render.rgba[i + 2],
  );
}

/// A legacy icon whose interior cell ([cx],[cy]) carries palette [index], on an
/// index-0 field, at [bpp] bits/pixel. Used to sample a known index's colour.
ViLegacyIcon _iconWithCells(int bpp, Map<int, int> cellIndexByLinear) {
  final byteLen = bpp == 8 ? 1024 : (bpp == 4 ? 512 : 128);
  final body = Uint8List(byteLen);
  cellIndexByLinear.forEach((pixel, index) {
    switch (bpp) {
      case 8:
        body[pixel] = index;
      case 4:
        final b = body[pixel >> 1];
        body[pixel >> 1] = (pixel & 1) == 0
            ? (b & 0x0f) | ((index & 0x0f) << 4)
            : (b & 0xf0) | (index & 0x0f);
      case 1:
        if ((index & 1) != 0) body[pixel >> 3] |= 1 << (7 - (pixel & 7));
    }
  });
  return decodeLegacyIcon(body, bpp)!;
}

/// A real 1×1 PNG (67 bytes): decodable by `Image.memory`, and its IHDR reports
/// 1×1 to `decodePngEnvelope`.
final Uint8List _png1x1 = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

DecodedSection _section(String tag, List<int> body, {int index = 0}) {
  final bytes = Uint8List.fromList(body);
  return DecodedSection(
    section: ViSection(tag: tag, index: index, dataOffset: 0, bytes: bytes),
    bytes: bytes,
    wasCompressed: false,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  test('extractViImages locates a PNG embedded after a header', () {
    // A DSIM-style payload: some header bytes, then the PNG.
    final body = [0, 0, 0, 0, 0x14, 0x14, ..._png1x1];
    final off = 6;
    final images = extractViImages([_section('DSIM', body)]);
    expect(images.pngs, hasLength(1));
    final png = images.pngs.single;
    expect(png.tag, 'DSIM');
    expect((png.width, png.height), (1, 1));
    expect(png.bytes, equals(Uint8List.fromList(body.sublist(off))));
  });

  test('extractViImages finds multiple PNGs and a raw MNGI PNG', () {
    final two = [..._png1x1, 0x00, 0x00, ..._png1x1];
    final images = extractViImages([
      _section('DSIM', two),
      _section('MNGI', _png1x1),
    ]);
    expect(images.pngs.map((p) => p.tag), ['DSIM', 'DSIM', 'MNGI']);
  });

  test('extractViImages decodes legacy icon payloads', () {
    final images = extractViImages([
      _section('icl8', List<int>.filled(1024, 7)),
      _section('ICON', List<int>.filled(128, 0xff)),
    ]);
    expect(images.icons.map((i) => i.tag), ['icl8', 'ICON']);
    expect(images.icons.first.icon.bpp, 8);
  });

  test('extractViImages ignores non-image payloads', () {
    final images = extractViImages([
      _section('vers', const [1, 2, 3, 4]),
    ]);
    expect(images.isEmpty, isTrue);
  });

  test('encodeQuickTimeRasterPng maps 24-bit RGB and 32-bit xRGB pixels', () {
    // 2×1 at 24-bit: a red pixel then a green pixel.
    final rgb = encodeQuickTimeRasterPng(
      ViQuickTimeRaster(
        width: 2,
        height: 1,
        depth: 24,
        pixels: Uint8List.fromList([255, 0, 0, 0, 255, 0]),
      ),
    );
    final decodedRgb = img.decodePng(rgb)!;
    expect(decodedRgb.getPixel(0, 0).r, 255);
    expect(decodedRgb.getPixel(1, 0).g, 255);
    // 1×1 at 32-bit xRGB: the leading pad byte is skipped, not read as red.
    final xrgb = encodeQuickTimeRasterPng(
      ViQuickTimeRaster(
        width: 1,
        height: 1,
        depth: 32,
        pixels: Uint8List.fromList([0x99, 0, 0, 255]),
      ),
    );
    final decodedXrgb = img.decodePng(xrgb)!;
    expect(decodedXrgb.getPixel(0, 0).r, 0);
    expect(decodedXrgb.getPixel(0, 0).b, 255);
  });

  test('a corpus PICT VI yields a decoded metafile image', () {
    final corpus = _corpusDir();
    if (corpus == null) return;
    final file = File(
      '${corpus.path}/tuftsBaxter_ROS-for-LabVIEW-Software/'
      'tuftsBaxter-ROS-for-LabVIEW-Software-cef95f1/ROS for LabVIEW Software/'
      'PlayArea/Controls/OriginalTest.vi',
    );
    if (!file.existsSync()) return;
    final images = extractViImages(decodeSections(file.readAsBytesSync()));
    expect(images.metafiles, hasLength(1));
    final metafile = images.metafiles.single;
    expect((metafile.tag, metafile.width, metafile.height), ('PICT', 411, 489));
    expect(metafile.depth, 24);
    // The encoded PNG round-trips through a PNG decoder at the same size.
    final decoded = img.decodePng(metafile.png);
    expect((decoded!.width, decoded.height), (411, 489));
  });

  testWidgets('empty images show the empty state', (tester) async {
    await _pump(tester, const ViImagesView(images: ViImages()));
    expect(find.text('No embedded images'), findsOneWidget);
  });

  testWidgets('gallery renders a PNG tile and a legacy icon tile', (
    tester,
  ) async {
    final images = ViImages(
      pngs: [
        EmbeddedPng(tag: 'MNGI', index: 0, width: 1, height: 1, bytes: _png1x1),
      ],
      icons: [
        EmbeddedLegacyIcon(
          tag: 'icl8',
          icon: decodeLegacyIcon(
            Uint8List.fromList(List<int>.filled(1024, 3)),
            8,
          )!,
        ),
      ],
    );
    await _pump(tester, ViImagesView(images: images));
    expect(find.text('Embedded images (2)'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('MNGI · 1×1'), findsOneWidget);
    expect(find.text('VI icon'), findsOneWidget);
    expect(find.textContaining('VI icon · 8-bit (icl8)'), findsOneWidget);
    expect(find.textContaining('failed to render'), findsNothing);
  });

  testWidgets('Images tab renders for a VI carrying an embedded PNG', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(
          initial: ViSummary(
            fileType: 'LVIN',
            creator: 'LBVW',
            formatVersion: 3,
            blocks: const ['DSIM'],
            name: 'imaged.vi',
          ),
          initialSource: 'test',
          initialImages: ViImages(
            pngs: [
              EmbeddedPng(
                tag: 'DSIM',
                index: 0,
                width: 1,
                height: 1,
                bytes: _png1x1,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.text('Embedded images (1)'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the demo VI reports no embedded images', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ViInspectorScreen()));
    await tester.tap(find.byKey(const Key('demo')));
    await tester.pump();
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.text('No embedded images'), findsOneWidget);
  });

  testWidgets(
    'the per-tile copy button writes the PNG image to the clipboard',
    (tester) async {
      final clip = _FakeImageClipboard();
      final images = ViImages(
        pngs: [
          EmbeddedPng(
            tag: 'MNGI',
            index: 0,
            width: 1,
            height: 1,
            bytes: _png1x1,
          ),
        ],
      );
      await _pump(tester, ViImagesView(images: images, clipboard: clip));
      await tester.tap(find.byTooltip('Copy image to clipboard'));
      await tester.pump(); // run the async copy
      await tester.pump(); // show the SnackBar
      expect(clip.writes, hasLength(1));
      expect(clip.writes.single, equals(_png1x1));
      expect(find.text('Copied MNGI image to clipboard'), findsOneWidget);
    },
  );

  testWidgets('a failed copy shows an honest notice', (tester) async {
    final clip = _FakeImageClipboard()..result = false;
    final images = ViImages(
      icons: [EmbeddedLegacyIcon(tag: 'icl8', icon: _icon(3, 8))],
    );
    await _pump(tester, ViImagesView(images: images, clipboard: clip));
    await tester.tap(find.byTooltip('Copy image to clipboard'));
    await tester.pump();
    await tester.pump();
    expect(clip.writes, hasLength(1));
    expect(find.textContaining('Could not copy'), findsOneWidget);
  });

  testWidgets('legacy icons group as depth-labeled VI-icon tiles', (
    tester,
  ) async {
    final images = ViImages(
      icons: [
        EmbeddedLegacyIcon(tag: 'ICON', icon: _icon(0xff, 1)), // all-1 grid
        EmbeddedLegacyIcon(tag: 'icl8', icon: _icon(3, 8)),
        EmbeddedLegacyIcon(tag: 'icl4', icon: _icon(0x11, 4)), // all-1 grid
      ],
    );
    await _pump(tester, ViImagesView(images: images));
    expect(find.text('VI icon'), findsOneWidget);
    // Ordered icl8 → icl4 → ICON, each its own depth-labeled tile.
    expect(find.textContaining('VI icon · 8-bit (icl8)'), findsOneWidget);
    expect(find.textContaining('VI icon · 4-bit (icl4)'), findsOneWidget);
    expect(find.textContaining('VI icon · 1-bit (ICON)'), findsOneWidget);
    // ICON's grid matches icl4's (both all-1) — noted only because it's proven.
    expect(find.textContaining('identical grid to icl4'), findsOneWidget);
    // One copy affordance per tile.
    expect(find.byTooltip('Copy image to clipboard'), findsNWidgets(3));
  });

  test('macIconArgb maps ICON (1-bit): 1=black, 0=white', () {
    expect(macIconArgb(1, 1), 0xFF000000);
    expect(macIconArgb(1, 0), 0xFFFFFFFF);
  });

  test('macIconArgb maps icl4 indices to the Mac 16-colour palette', () {
    expect(macIconArgb(4, 0), 0xFFFFFFFF); // white
    expect(macIconArgb(4, 3), 0xFFDD0806); // red
    expect(macIconArgb(4, 6), 0xFF0000D4); // blue
    expect(macIconArgb(4, 15), 0xFF000000); // black
  });

  test('macIconArgb maps icl8 indices to the Mac 256-colour palette', () {
    expect(macIconArgb(8, 0), 0xFFFFFFFF); // white (cube corner)
    expect(macIconArgb(8, 5), 0xFFFFFF00); // yellow (cube)
    expect(macIconArgb(8, 35), 0xFFFF0000); // pure red (cube)
    expect(macIconArgb(8, 215), 0xFFEE0000); // red ramp head
    expect(macIconArgb(8, 245), 0xFFEEEEEE); // gray ramp head
    expect(macIconArgb(8, 255), 0xFF000000); // black
  });

  testWidgets('icl8 painter draws each index in its palette colour', (
    tester,
  ) async {
    // Four interior cells carry indices 0/35/5/255 on an index-0 field.
    final icon = _iconWithCells(8, {
      5 * 32 + 5: 0, // white
      5 * 32 + 6: 35, // pure red
      5 * 32 + 7: 5, // yellow
      5 * 32 + 8: 255, // black
    });
    final render = await _renderIcon(tester, icon);
    expect(_cellColor(render, 5, 5), const Color(0xFFFFFFFF));
    expect(_cellColor(render, 6, 5), const Color(0xFFFF0000));
    expect(_cellColor(render, 7, 5), const Color(0xFFFFFF00));
    expect(_cellColor(render, 8, 5), const Color(0xFF000000));
  });

  testWidgets('a multi-index icl8 icon renders many distinct colours', (
    tester,
  ) async {
    // A palette-index gradient across the top rows → many distinct colours,
    // proving the render is not a two-tone mask.
    final icon = _iconWithCells(8, {
      for (var i = 0; i < 32 * 8; i++) i: i % 256,
    });
    final render = await _renderIcon(tester, icon);
    final colours = <int>{};
    for (var cy = 0; cy < 8; cy++) {
      for (var cx = 0; cx < 32; cx++) {
        colours.add(_cellColor(render, cx, cy).toARGB32());
      }
    }
    expect(colours.length, greaterThan(2));
  });

  testWidgets('ICON painter renders index 1 as black on a white field', (
    tester,
  ) async {
    final icon = _iconWithCells(1, {5 * 32 + 5: 1});
    final render = await _renderIcon(tester, icon);
    expect(
      _cellColor(render, 5, 5),
      const Color(0xFF000000),
    ); // set bit → black
    expect(_cellColor(render, 5, 6), const Color(0xFFFFFFFF)); // clear → white
  });

  test('encodeLegacyIconPng emits a decodable PNG carrying the shape', () {
    final png = encodeLegacyIconPng(_icon(0xff, 8));
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });
}
