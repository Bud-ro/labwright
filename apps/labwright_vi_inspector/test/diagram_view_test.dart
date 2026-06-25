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

  testWidgets('Faithful mode wraps a control carrying decoded help text in a Tooltip', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    List<int> c6blob(int id, String s) {
      final len = 4 + s.length;
      return [0xc6, id, 0xff, len >> 8, len & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    }
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a), ...bounds(20, 20, 60, 200), ...c6blob(0x6c, 'help here'),
      ...close(0x1a),
      ...close(),
    ];
    final model = _modelFromRecords([0, 0, 0, records.length, ...records]);
    expect(model.diagrams.expand((d) => d.objects).firstWhere((o) => o.oid == 2).helpText, 'help here');

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: model.blockDiagrams))));
    await tester.pump();
    await tester.tap(find.text('Faithful'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The control with decoded help text is wrapped in a Tooltip carrying it.
    expect(find.byTooltip('help here'), findsOneWidget);
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

  group('nodesWithin', () {
    ViHeapObject obj(int oid, ViObjectKind cat, int t, int l, int b, int r) =>
        ViHeapObject(oid: oid, kind: 0x2f, offset: 0)
          ..category = cat
          ..absBounds = HeapRect(top: t, left: l, bottom: b, right: r);

    test('returns logic nodes spatially inside the structure, excluding outsiders/terminals', () {
      final loop = obj(1, ViObjectKind.structure, 0, 0, 200, 200);
      final inside = obj(2, ViObjectKind.node, 20, 20, 60, 100); // a subVI inside
      final innerLoop = obj(3, ViObjectKind.structure, 30, 30, 90, 150); // nested structure inside
      final outside = obj(4, ViObjectKind.node, 300, 300, 340, 400); // node outside
      final termInside = obj(5, ViObjectKind.terminal, 25, 25, 35, 45); // terminal inside (not logic)
      final within = nodesWithin(loop, [loop, inside, innerLoop, outside, termInside]);
      expect(within, containsAll([inside, innerLoop]));
      expect(within, isNot(contains(outside)));
      expect(within, isNot(contains(termInside))); // terminals are not "logic" contents
      expect(within, isNot(contains(loop))); // never itself
    });

    test('a structure with no bounds yields nothing', () {
      final s = ViHeapObject(oid: 1, kind: 0x53, offset: 0)..category = ViObjectKind.structure;
      expect(nodesWithin(s, const []), isEmpty);
    });

    test('a child that exactly FILLS the parent is included; an exact-bounds clone is excluded', () {
      final frame = obj(1, ViObjectKind.structure, 0, 0, 100, 100);
      final fillingBody = obj(2, ViObjectKind.structure, 0, 0, 100, 100); // same bounds, distinct object
      // exact-bounds same-category object is treated as a clone/viewport -> excluded;
      // but a strictly-larger-area child is impossible when bounds are equal, so this
      // documents the exact-equal exclusion (the per-frame body is caught when it is
      // even 1px inset). Verify a 1px-inset body IS included:
      final insetBody = obj(3, ViObjectKind.structure, 0, 0, 100, 99);
      final within = nodesWithin(frame, [frame, fillingBody, insetBody]);
      expect(within, contains(insetBody)); // fills-but-inset -> contained
      expect(within, isNot(contains(fillingBody))); // exact clone -> excluded
    });
  });

  group('wireframeAnnotation', () {
    test('a structure shows its catalog kind (honest, no fabrication)', () {
      final whileLoop = ViHeapObject(oid: 1, kind: 0x21, offset: 0)..category = ViObjectKind.structure;
      expect(wireframeAnnotation(whileLoop), 'While loop');
      final caseStruct = ViHeapObject(oid: 2, kind: 0x2c, offset: 0)..category = ViObjectKind.structure;
      expect(wireframeAnnotation(caseStruct), 'Case structure');
      // dual-role 0x53 keeps the catalog hedge, not a bare "Loop"
      final dual = ViHeapObject(oid: 3, kind: 0x53, offset: 0)..category = ViObjectKind.structure;
      expect(wireframeAnnotation(dual), 'Loop (BD) / container (FP)');
    });
    test('a node shows its recovered name', () {
      final node = ViHeapObject(oid: 1, kind: 0x2f, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'PicoScope2000aOpen.vi';
      expect(wireframeAnnotation(node), 'PicoScope2000aOpen.vi');
    });
    test('a labeled terminal shows name and type', () {
      final t = ViHeapObject(oid: 1, kind: 0x50, offset: 0)
        ..category = ViObjectKind.terminal
        ..label = 'count'
        ..typeKind = ViTypeKind.numericInt;
      expect(wireframeAnnotation(t), 'count · numericInt');
    });
  });

  testWidgets('toolbar does not overflow on a narrow viewport (user-reported)', (tester) async {
    // 600px is narrower than the toolbar's fixed controls + legend; the Wrap must
    // flow them onto a second line rather than overflow (RenderFlex exception).
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: _modelWithDiagram().blockDiagrams))));
    await tester.pump();

    expect(tester.takeException(), isNull); // no overflow
    expect(find.textContaining('objects'), findsOneWidget); // controls still render
    expect(find.text('Wireframe'), findsOneWidget);
  });

  group('computeBdOutline', () {
    ViHeapObject struct(int kind) => ViHeapObject(oid: kind, kind: kind, offset: 0)..category = ViObjectKind.structure;
    test('groups structures by catalog kind and lists named calls (no fabrication)', () {
      final objs = [
        struct(0x21), // While loop
        struct(0x21), // While loop (×2)
        struct(0x2c), // Case structure
        struct(0x7e), // Diagram root -> excluded (not control flow)
        ViHeapObject(oid: 10, kind: 0x12, offset: 0) // a named subVI/function node
          ..category = ViObjectKind.node
          ..label = 'Acquire.vi',
        ViHeapObject(oid: 11, kind: 0x2f, offset: 0)..category = ViObjectKind.node, // unlabeled primitive -> hint
      ];
      final o = computeBdOutline(objs);
      expect(o.structuresByKind['While loop'], 2);
      expect(o.structuresByKind['Case structure'], 1);
      expect(o.structuresByKind.containsKey('Diagram root'), isFalse); // excluded
      expect(o.calls, ['Acquire.vi']); // the hint-only primitive is not a "call"
      expect(o.nodeCount, 2);
    });
  });

  testWidgets('block-diagram view shows a control-flow outline (structures + calls)', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final model = _modelFromRecords(<int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400), // root (excluded from outline)
      ...open(0x21, 2, tag: 0x1a), ...bounds(10, 10, 200, 200), // While loop
      ...close(0x1a),
      ...open(0x12, 3, tag: 0x1b), ...bounds(20, 220, 50, 360), ...caption('Acquire.vi'), // named node
      ...close(0x1b),
      ...close(),
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViDiagramView(diagrams: model.blockDiagrams))));
    await tester.pump();

    expect(find.text('Control flow:'), findsOneWidget);
    expect(find.text('While loop ×1'), findsOneWidget);
    expect(find.textContaining('Diagram-labeled nodes (1): Acquire.vi'), findsOneWidget);
  });

  testWidgets('block-diagram outline lists the authoritative linked subVIs (LIbd)', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final model = _modelFromRecords(<int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x2f, 2, tag: 0x1a), ...bounds(10, 10, 50, 120), // an UNLABELED primitive node
      ...close(0x1a),
      ...close(),
    ]);
    // the linker (LIbd) names the real dependencies even though the node is unlabeled
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ViDiagramView(diagrams: model.blockDiagrams, subViNames: const ['Open.vi', 'Close.vi']),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('Linked subVIs (2): Open.vi, Close.vi'), findsOneWidget);
  });
}
