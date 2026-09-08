import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/images_view.dart';

import 'util.dart';

ViModel modelWithControls() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x57, 2, tag: 0x1a),
  ...bounds(20, 20, 50, 160),
  ...open(0x0d, 3, tag: 0x1b),
  ...bounds(22, 22, 48, 158),
  ...enum2e(['Low', 'High']),
  ...close(0x1b),
  ...close(0x1a),
  ...open(0x4f, 4, tag: 0x1c),
  ...bounds(80, 20, 110, 160),
  ...close(0x1c),
  ...close(),
]);

ViModel modelWithDiagram() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x12, 2, tag: 0x1a),
  ...bounds(10, 20, 40, 160),
  ...caption('Acquire'),
  ...close(0x1a),
  ...open(0x50, 3, tag: 0x1b),
  ...bounds(60, 20, 77, 120),
  ...caption('Channel'),
  ...close(0x1b),
  ...close(),
]);

Future<void> pumpView(
  WidgetTester tester,
  ViModel model, {
  List<String> subVis = const [],
  Size view = const Size(1000, 1000),
}) => pumpBody(
  tester,
  ViDiagramView(diagrams: model.blockDiagrams, subViNames: subVis),
  view: view,
);

Future<ui.Image> _tinyIcon() {
  final completer = Completer<ui.Image>();
  final rgba = Uint8List.fromList([0, 0, 0, 255, 0, 0, 0, 0]);
  ui.decodeImageFromPixels(
    rgba,
    2,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  test('remapPrimIcon substitutes palette colours, preserves alpha', () async {
    final icon = await _tinyIcon();
    final remapped = await remapPrimIcon(icon, {0x000000: 0x777777});
    final data = await rgbaOf(remapped);
    expect(data.sublist(0, 4), [0x77, 0x77, 0x77, 255]);
    expect(data[7], 0, reason: 'transparent pixel stays transparent');
  });

  test('terminals keep LabVIEW datatype colors; unknown stays neutral', () {
    const rows = {
      ViTypeKind.numericFloat: Color(0xFFFF6600),
      ViTypeKind.numericInt: Color(0xFF0000FF),
      ViTypeKind.enumRing: Color(0xFF0000FF),
      ViTypeKind.string: Color(0xFFFF00FF),
      ViTypeKind.boolean: Color(0xFF006600),
      ViTypeKind.path: Color(0xFF006666),
      ViTypeKind.unknown: Color(0xFF8A8A8A),
    };
    rows.forEach((k, want) => expect(labviewTypeColor(k), want, reason: '$k'));
  });

  testWidgets('layout view renders objects with a legend', (tester) async {
    await pumpView(tester, modelWithDiagram());
    expect(find.textContaining('objects'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.textContaining('node'), findsWidgets);
  });

  testWidgets('tapping a structure with members highlights, does not crash', (
    tester,
  ) async {
    final model = modelFromRecords(<int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x53, 2, tag: 0x1a),
      ...bounds(10, 10, 200, 200),
      ...childRef(9),
      ...open(0x50, 9, tag: 0x1b),
      ...bounds(20, 20, 60, 120),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ]);
    await pumpView(tester, model);
    await tester.tapAt(const Offset(120, 120));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('BD view shows the VI-image strip when an icon is present', (
    tester,
  ) async {
    final images = ViImages(
      icons: [
        EmbeddedLegacyIcon(
          tag: 'icl8',
          icon: ViLegacyIcon(bpp: 8, pixels: List.filled(1024, 0)),
        ),
      ],
    );
    await pumpBody(
      tester,
      ViDiagramView(
        diagrams: modelWithDiagram().blockDiagrams,
        viImages: images,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('VI icon'), findsOneWidget);
    await pumpBody(
      tester,
      ViDiagramView(
        diagrams: modelWithDiagram().blockDiagrams,
        viImages: images,
        isFrontPanel: true,
      ),
    );
    expect(find.textContaining('VI icon'), findsNothing);
  });

  testWidgets('empty model shows an honest placeholder, not a crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: null))),
    );
    expect(find.textContaining('No decodable layout'), findsOneWidget);
  });

  testWidgets('toolbar does not overflow on a narrow viewport', (tester) async {
    await pumpView(tester, modelWithDiagram(), view: const Size(600, 900));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('objects'), findsOneWidget);
  });

  testWidgets('BD view shows a control-flow outline (structures + calls)', (
    tester,
  ) async {
    await pumpView(
      tester,
      modelFromRecords(<int>[
        ...open(0x7e, 1),
        ...bounds(0, 0, 400, 400),
        ...open(0x21, 2, tag: 0x1a),
        ...bounds(10, 10, 200, 200),
        ...close(0x1a),
        ...open(0x12, 3, tag: 0x1b),
        ...bounds(20, 220, 50, 360),
        ...caption('Acquire.vi'),
        ...close(0x1b),
        ...close(),
      ]),
    );
    expect(find.text('Control flow:'), findsOneWidget);
    expect(find.text('While loop ×1'), findsOneWidget);
    expect(
      find.textContaining('Diagram-labeled nodes (1): Acquire.vi'),
      findsOneWidget,
    );
    expect(find.text('Class confidence:'), findsOneWidget);
    expect(find.textContaining('not dataflow'), findsOneWidget);
  });

  testWidgets('BD outline lists the linked subVIs from the LIbd block', (
    tester,
  ) async {
    await pumpView(
      tester,
      modelFromRecords(<int>[
        ...open(0x7e, 1),
        ...bounds(0, 0, 400, 400),
        ...open(0x2f, 2, tag: 0x1a),
        ...bounds(10, 10, 50, 120),
        ...close(0x1a),
        ...close(),
      ]),
      subVis: const ['Open.vi', 'Close.vi'],
    );
    expect(
      find.textContaining('Linked subVIs (2): Open.vi, Close.vi'),
      findsOneWidget,
    );
  });
}
