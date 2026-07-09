import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/image_clipboard.dart';
import 'package:labwright_vi_inspector/src/images_view.dart';
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

ViLegacyIcon _icon(int fill, int bpp) => decodeLegacyIcon(
  Uint8List.fromList(
    List<int>.filled(bpp == 8 ? 1024 : (bpp == 4 ? 512 : 128), fill),
  ),
  bpp,
)!;

/// Counts foreground pixels (≈0xE0 grey) in a [LegacyIconPainter] render — the
/// icon SHAPE is non-blank when this is > 0, regardless of bit depth.
Future<int> _foregroundPixels(WidgetTester tester, ViLegacyIcon icon) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: CustomPaint(
              size: const Size(32, 32),
              painter: LegacyIconPainter(icon),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  var count = 0;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(); // defaults to rawRgba
    final bytes = data!.buffer.asUint8List();
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i] > 0xB0 && bytes[i + 1] > 0xB0 && bytes[i + 2] > 0xB0)
        count++;
    }
  });
  return count;
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

  testWidgets('an all-nonzero-index icon renders non-blank at 8-bit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(64, 64);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final filled = await _foregroundPixels(tester, _icon(0xff, 8));
    final blank = await _foregroundPixels(tester, _icon(0, 8));
    expect(filled, greaterThan(0));
    expect(blank, 0);
  });

  test('encodeLegacyIconPng emits a decodable PNG carrying the shape', () {
    final png = encodeLegacyIconPng(_icon(0xff, 8));
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });
}
