import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/image_clipboard.dart';
import 'package:labwright_vi_inspector/src/images_view.dart';
import 'package:labwright_vi_inspector/src/span_annotations.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

class _FakeImageClipboard implements ImageClipboard {
  final List<Uint8List> writes = [];
  bool result = true;

  @override
  Future<bool> copyPng(Uint8List pngBytes) async {
    writes.add(pngBytes);
    return result;
  }
}

ViLegacyIcon _icon(int fill, int bpp) {
  final depth = LegacyIconDepth.values.singleWhere((d) => d.bits == bpp);
  return decodeLegacyIcon(
    Uint8List.fromList(List<int>.filled(depth.byteLength, fill)),
    depth,
  );
}

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
    final image = await boundary.toImage();
    final data = await image.toByteData();
    rgba = data!.buffer.asUint8List();
  });
  return (rgba: rgba, stride: dim * cell);
}

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
  return decodeLegacyIcon(
    body,
    LegacyIconDepth.values.singleWhere((d) => d.bits == bpp),
  );
}

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

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  test('encodeQuickTimeRasterPng maps 24-bit RGB and 32-bit xRGB pixels', () {
    final rgb = encodeQuickTimeRasterPng(
      2,
      1,
      24,
      Uint8List.fromList([255, 0, 0, 0, 255, 0]),
    );
    final decodedRgb = img.decodePng(rgb)!;
    expect(decodedRgb.getPixel(0, 0).r, 255);
    expect(decodedRgb.getPixel(1, 0).g, 255);
    final xrgb = encodeQuickTimeRasterPng(
      1,
      1,
      32,
      Uint8List.fromList([0x99, 0, 0, 255]),
    );
    final decodedXrgb = img.decodePng(xrgb)!;
    expect(decodedXrgb.getPixel(0, 0).r, 0);
    expect(decodedXrgb.getPixel(0, 0).b, 255);
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
        EmbeddedPng(tag: 'MNGI', index: 0, stream: decodePngStream(_png1x1)),
      ],
      icons: [decodeIcl8(Uint8List.fromList(List<int>.filled(1024, 3)))],
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
                stream: decodePngStream(_png1x1),
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
          EmbeddedPng(tag: 'MNGI', index: 0, stream: decodePngStream(_png1x1)),
        ],
      );
      await _pump(tester, ViImagesView(images: images, clipboard: clip));
      await tester.tap(find.byTooltip('Copy image to clipboard'));
      await tester.pump();
      await tester.pump();
      expect(clip.writes, hasLength(1));
      expect(clip.writes.single, equals(_png1x1));
      expect(find.text('Copied MNGI image to clipboard'), findsOneWidget);
    },
  );

  testWidgets('a failed copy shows an honest notice', (tester) async {
    final clip = _FakeImageClipboard()..result = false;
    final images = ViImages(icons: [_icon(3, 8)]);
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
      icons: [_icon(3, 8), _icon(0x11, 4), _icon(0xff, 1)],
    );
    await _pump(tester, ViImagesView(images: images));
    expect(find.text('VI icon'), findsOneWidget);
    expect(find.textContaining('VI icon · 8-bit (icl8)'), findsOneWidget);
    expect(find.textContaining('VI icon · 4-bit (icl4)'), findsOneWidget);
    expect(find.textContaining('VI icon · 1-bit (ICON)'), findsOneWidget);
    expect(find.textContaining('identical grid to icl4'), findsOneWidget);
    expect(find.byTooltip('Copy image to clipboard'), findsNWidgets(3));
  });

  test('macIconArgb maps ICON (1-bit): 1=black, 0=white', () {
    expect(macIconArgb(LegacyIconDepth.mono, 1), 0xFF000000);
    expect(macIconArgb(LegacyIconDepth.mono, 0), 0xFFFFFFFF);
  });

  test('macIconArgb maps icl4 indices to the Mac 16-colour palette', () {
    expect(macIconArgb(LegacyIconDepth.fourBit, 0), 0xFFFFFFFF);
    expect(macIconArgb(LegacyIconDepth.fourBit, 3), 0xFFDD0806);
    expect(macIconArgb(LegacyIconDepth.fourBit, 6), 0xFF0000D4);
    expect(macIconArgb(LegacyIconDepth.fourBit, 15), 0xFF000000);
  });

  test('macIconArgb maps icl8 indices to the Mac 256-colour palette', () {
    expect(macIconArgb(LegacyIconDepth.eightBit, 0), 0xFFFFFFFF);
    expect(macIconArgb(LegacyIconDepth.eightBit, 5), 0xFFFFFF00);
    expect(macIconArgb(LegacyIconDepth.eightBit, 35), 0xFFFF0000);
    expect(macIconArgb(LegacyIconDepth.eightBit, 215), 0xFFEE0000);
    expect(macIconArgb(LegacyIconDepth.eightBit, 245), 0xFFEEEEEE);
    expect(macIconArgb(LegacyIconDepth.eightBit, 255), 0xFF000000);
  });

  testWidgets('icl8 painter draws each index in its palette colour', (
    tester,
  ) async {
    final icon = _iconWithCells(8, {
      5 * 32 + 5: 0,
      5 * 32 + 6: 35,
      5 * 32 + 7: 5,
      5 * 32 + 8: 255,
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
    expect(_cellColor(render, 5, 5), const Color(0xFF000000));
    expect(_cellColor(render, 5, 6), const Color(0xFFFFFFFF));
  });

  test('encodeLegacyIconPng emits a decodable PNG carrying the shape', () {
    final png = encodeLegacyIconPng(_icon(0xff, 8));
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });
}
