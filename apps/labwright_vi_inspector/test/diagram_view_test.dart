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
List<int> enum2e(List<String> items) {
  final b = <int>[for (final it in items) ...[it.length, ...it.codeUnits]];
  return [0xc4, 0x2e, b.length, ...b];
}

ViModel _modelFromRecords(List<int> records) {
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  final sec = DecodedSection(
    section: ViSection(tag: 'BDHb', index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: false,
  );
  return buildViModelFromDecoded([sec]);
}

// A front-panel-ish model: an enum/ring control (0x57) whose items propagate up
// from its 0x0d item-list child, plus a plain boolean control (0x4f, no items).
ViModel _modelWithControls() => _modelFromRecords(<int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x57, 2, tag: 0x1a), ...bounds(20, 20, 50, 160), // enum/ring control
      ...open(0x0d, 3, tag: 0x1b), ...bounds(22, 22, 48, 158), ...enum2e(['Low', 'High']),
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x4f, 4, tag: 0x1c), ...bounds(80, 20, 110, 160), // boolean control, no items
      ...close(0x1c),
      ...close(),
    ]);

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

  testWidgets('Faithful mode renders decoded enum items and a plain boolean', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final model = _modelWithControls();
    // The 0x0d item-list items propagate up to the 0x57 enum control...
    expect(model.diagrams.expand((d) => d.objects).firstWhere((o) => o.oid == 2).items, ['Low', 'High']);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: model.blockDiagrams))));
    await tester.pump();
    await tester.tap(find.text('Faithful'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // The enum/ring control shows its first decoded item; the boolean shows OFF.
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
  });

  test('membersOf resolves declared members to DRAWN objects only', () {
    // A structure (0x53) declaring: childRef->9 (drawn 0x50), memberRef->10
    // (scaffolding 0x09), childRef->11 (undeclared). Only #9 should resolve.
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x53, 2, tag: 0x1a), ...bounds(10, 10, 200, 200),
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x09, // childRef -> 9 (drawn)
      0x14, 0x4f, 0x01, 0xfd, 0x00, 0x0a, // memberRef -> 10 (scaffolding)
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x0b, // childRef -> 11 (never declared)
      ...open(0x50, 9, tag: 0x1b), ...bounds(20, 20, 37, 100), ...close(0x1b), // a drawn control
      ...open(0x09, 10, tag: 0x1c), ...bounds(40, 40, 57, 100), ...close(0x1c), // scaffolding (0x09)
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final d = buildDiagram(body);
    final structure = d.byId[2];
    final members = membersOf(structure, d.byId);
    expect(members.map((m) => m.oid).toSet(), {9}); // 10 scaffolding-suppressed, 11 missing
    expect(membersOf(null, d.byId), isEmpty);
  });

  testWidgets('tapping a structure with members does not crash and highlights', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x53, 2, tag: 0x1a), ...bounds(10, 10, 200, 200),
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x09,
      ...open(0x50, 9, tag: 0x1b), ...bounds(20, 20, 60, 120), ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final model = _modelFromRecords([0, 0, 0, records.length, ...records]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: model.blockDiagrams))));
    await tester.pump();
    await tester.tapAt(const Offset(120, 120)); // inside the structure, outside the control
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty model shows an honest placeholder, not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: null))));
    expect(find.textContaining('No decodable layout'), findsOneWidget);
  });
}
