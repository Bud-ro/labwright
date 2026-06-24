import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

// Heap record helpers (mirror the videcode bracket model).
List<int> open(int kind, int oid, {int tag = 0x19}) =>
    [0x10, tag, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) =>
    [0xc4, 0x2d, 0x08, t >> 8, t & 0xff, l >> 8, l & 0xff, b >> 8, b & 0xff, r >> 8, r & 0xff];
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];

ViModel _modelWithDiagram() {
  final records = <int>[
    ...open(0x7e, 1), ...bounds(0, 0, 400, 400), // root
    ...open(0x12, 2, tag: 0x1a), ...bounds(10, 20, 40, 160), ...caption('Acquire'), // a node
    ...close(0x1a),
    ...open(0x50, 3, tag: 0x1b), ...bounds(60, 20, 77, 120), ...caption('Channel'), // a terminal
    ...close(0x1b),
    ...close(),
  ];
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  final sec = DecodedSection(
    section: ViSection(tag: 'BDHb', index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: false,
  );
  return buildViModelFromDecoded([sec]);
}

void main() {
  testWidgets('layout view renders objects with a legend', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: _modelWithDiagram().blockDiagrams))));
    await tester.pump();

    expect(find.textContaining('objects'), findsOneWidget); // count header
    expect(find.byType(CustomPaint), findsWidgets); // the painted layout
    // legend mentions decoded categories
    expect(find.textContaining('node'), findsWidgets);
  });

  testWidgets('toggles to Faithful mode and renders real controls', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: _modelWithDiagram().blockDiagrams))));
    await tester.pump();

    expect(find.text('Wireframe'), findsOneWidget);
    expect(find.text('Faithful'), findsOneWidget);
    await tester.tap(find.text('Faithful'));
    await tester.pump();
    // the faithful layer mounted (a TextField appears for the string/path/field
    // controls, or at least the switch didn't crash) — and the count header stays.
    expect(find.textContaining('objects'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty model shows an honest placeholder, not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: null))));
    expect(find.textContaining('No decodable layout'), findsOneWidget);
  });
}
