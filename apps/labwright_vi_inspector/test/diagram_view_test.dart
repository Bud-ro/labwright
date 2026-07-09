import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/images_view.dart';

import 'util.dart';

/// An enum/ring control (0x57, items via its 0x0d child) + a plain boolean.
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

/// A named node + a labeled terminal under the diagram root.
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

void main() {
  test('terminals keep LabVIEW datatype colors; unknown stays neutral', () {
    const rows = {
      ViTypeKind.numericFloat: Color(0xFFFF8000),
      ViTypeKind.numericInt: Color(0xFF0066CC),
      ViTypeKind.enumRing: Color(0xFF0066CC),
      ViTypeKind.path: Color(0xFF669900),
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

  testWidgets('toggles to Faithful mode and renders real controls', (
    tester,
  ) async {
    await pumpView(tester, modelWithDiagram());
    expect(find.text('Wireframe'), findsOneWidget);
    expect(find.text('Faithful'), findsOneWidget);
    await tester.tap(find.text('Faithful'));
    await tester.pump();
    expect(find.textContaining('objects'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Faithful mode renders decoded enum items and a plain boolean', (
    tester,
  ) async {
    final model = modelWithControls();
    expect(
      model.diagrams
          .expand((d) => d.objects)
          .firstWhere((o) => o.oid == 2)
          .items,
      ['Low', 'High'],
    );
    await pumpView(tester, model);
    await tester.tap(find.text('Faithful'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
  });

  testWidgets('Faithful mode wraps decoded help text in a Tooltip', (
    tester,
  ) async {
    final model = modelFromRecords(<int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(20, 20, 60, 200),
      ...helpRecord('help here'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(
      model.diagrams
          .expand((d) => d.objects)
          .firstWhere((o) => o.oid == 2)
          .helpText,
      'help here',
    );
    await pumpView(tester, model);
    await tester.tap(find.text('Faithful'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('help here'), findsOneWidget);
  });

  test('membersOf resolves declared members to DRAWN objects only', () {
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x53, 2, tag: 0x1a), ...bounds(10, 10, 200, 200),
      ...childRef(9),
      ...memberRef(10), // scaffolding, not drawn
      ...childRef(11), // never declared
      ...open(0x50, 9, tag: 0x1b), ...bounds(20, 20, 37, 100), ...close(0x1b),
      ...open(0x09, 10, tag: 0x1c), ...bounds(40, 40, 57, 100), ...close(0x1c),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(
      Uint8List.fromList([0, 0, 0, records.length, ...records]),
    );
    expect(membersOf(d.byId[2], d.byId).map((m) => m.oid).toSet(), {9});
    expect(membersOf(null, d.byId), isEmpty);
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
    // The front panel never shows the identity strip.
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

  group('nodesWithin', () {
    ViHeapObject at(int oid, ViObjectKind cat, (int, int, int, int) r) =>
        heapObj(0x2f, oid: oid, cat: cat, at: r);

    test('keeps logic nodes spatially inside; drops outsiders/terminals', () {
      final loop = at(1, ViObjectKind.structure, (0, 0, 200, 200));
      final inside = at(2, ViObjectKind.node, (20, 20, 60, 100));
      final innerLoop = at(3, ViObjectKind.structure, (30, 30, 90, 150));
      final outside = at(4, ViObjectKind.node, (300, 300, 340, 400));
      final termInside = at(5, ViObjectKind.terminal, (25, 25, 35, 45));
      final within = nodesWithin(loop, [
        loop,
        inside,
        innerLoop,
        outside,
        termInside,
      ]);
      expect(within, containsAll([inside, innerLoop]));
      expect(within, isNot(contains(outside)));
      expect(within, isNot(contains(termInside)));
      expect(within, isNot(contains(loop)));
    });

    test('a structure with no bounds yields nothing', () {
      final s = heapObj(0x53, cat: ViObjectKind.structure);
      expect(nodesWithin(s, const []), isEmpty);
    });

    test(
      'an exactly-filling child is included; an exact-bounds clone is not',
      () {
        final frame = at(1, ViObjectKind.structure, (0, 0, 100, 100));
        final fillingClone = at(2, ViObjectKind.structure, (0, 0, 100, 100));
        final insetBody = at(3, ViObjectKind.structure, (0, 0, 100, 99));
        final within = nodesWithin(frame, [frame, fillingClone, insetBody]);
        expect(within, contains(insetBody));
        expect(within, isNot(contains(fillingClone)));
      },
    );
  });

  test('wireframeAnnotation: catalog kind, recovered name, terminal type', () {
    final rows = <(ViHeapObject, String)>[
      (heapObj(0x21, cat: ViObjectKind.structure), 'While loop'),
      (heapObj(0x2c, cat: ViObjectKind.structure), 'Case structure'),
      (
        heapObj(0x53, cat: ViObjectKind.structure),
        'Loop (BD) / container (FP)',
      ),
      (
        heapObj(0x2f, cat: ViObjectKind.node, label: 'PicoScope2000aOpen.vi'),
        'PicoScope2000aOpen.vi',
      ),
      (
        heapObj(
          0x50,
          cat: ViObjectKind.terminal,
          label: 'count',
          typeKind: ViTypeKind.numericInt,
        ),
        'count · numericInt',
      ),
    ];
    for (final (o, want) in rows) {
      expect(wireframeAnnotation(o), want, reason: want);
    }
  });

  testWidgets('toolbar does not overflow on a narrow viewport', (tester) async {
    await pumpView(tester, modelWithDiagram(), view: const Size(600, 900));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('objects'), findsOneWidget);
    expect(find.text('Wireframe'), findsOneWidget);
  });

  group('computeBdOutline', () {
    ViHeapObject struct(int kind) =>
        heapObj(kind, oid: kind, cat: ViObjectKind.structure);

    test('groups structures by catalog kind; lists labeled-node captions', () {
      final o = computeBdOutline([
        struct(0x21),
        struct(0x21),
        struct(0x2c),
        struct(0x7e), // diagram root: excluded (not control flow)
        heapObj(0x12, oid: 10, cat: ViObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x2f, oid: 11, cat: ViObjectKind.node), // unlabeled primitive
      ]);
      expect(o.structuresByKind['While loop'], 2);
      expect(o.structuresByKind['Case structure'], 1);
      expect(o.structuresByKind.containsKey('Diagram root'), isFalse);
      expect(o.labeledNodes, ['Acquire.vi']);
      expect(o.nodeCount, 2);
      expect(o.confidence.values.fold<int>(0, (a, b) => a + b), 5);
    });

    test('emits NO wire/edge/dataflow linkage (no-fabricated-wires)', () {
      final o = computeBdOutline([
        struct(0x21),
        struct(0x2c),
        heapObj(0x12, oid: 10, cat: ViObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x12, oid: 11, cat: ViObjectKind.node, label: 'Write.vi'),
      ]);
      final text = [
        ...o.structuresByKind.keys,
        ...o.labeledNodes,
      ].join(' ').toLowerCase();
      for (final banned in [
        'wire',
        'edge',
        'dataflow',
        'connect',
        '->',
        '→',
        'flows to',
        'wires to',
      ]) {
        expect(text.contains(banned), isFalse, reason: banned);
      }
    });
  });

  testWidgets('BD view shows a control-flow outline (structures + calls)', (
    tester,
  ) async {
    // The no-fabricated-wires contract is enforced by the computeBdOutline
    // unit test; the view keeps its honest "not dataflow" disclaimer.
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
