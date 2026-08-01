import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

/// A block diagram whose subVI-call node's connector-pane control has been
/// spliced into the heap (an inlined/malleable subVI): a `0x51` control terminal
/// nested under a `0x13` const-DCO inside a `0x15` structural record, carrying a
/// named `0x0a` caption child — plus a bare unnamed `0x50` constant terminal in
/// the same subtree. Only the bare constant is a top-level diagram object.
ViModel modelWithInlinedSubViControl() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x1b, 2, tag: 0x1a),
  ...open(0x15, 3, tag: 0x1b),
  ...open(0x13, 4, tag: 0x1c),
  ...open(0x51, 5, tag: 0x1d), // named inlined subVI connector control
  ...bounds(200, 200, 220, 300),
  ...open(0x0a, 6, tag: 0x1e),
  ...bounds(180, 200, 197, 285),
  ...caption('Requirement ID'),
  ...close(0x1e),
  ...close(0x1d),
  ...open(0x50, 7, tag: 0x1d), // bare unnamed diagram constant
  ...bounds(120, 120, 140, 160),
  ...close(0x1d),
  ...close(0x1c),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
]);

/// objFlags (raw `0x0cb`) as a `u32` attribute record; bit `0x08` hides a label.
List<int> objFlags(int v) => [
  0x84,
  0xcb,
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

/// A scalar numeric diagram constant: a `0x50` value carrier under a `0x13`
/// `bDConstDCO`, whose `0x0a` name child carries a caption but is HIDDEN
/// (objFlags bit `0x08`) — the profile of an `x`/`y` constant. LabVIEW paints
/// the constant box (the hidden name is not drawn), so it must stay in the
/// drawn set even though its caption is now decoded.
ViModel modelWithHiddenLabeledConstant() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x13, 2, tag: 0x1a),
  ...open(0x50, 3, tag: 0x1b),
  ...bounds(120, 120, 140, 160),
  ...open(0x0a, 4, tag: 0x1c),
  ...bounds(100, 120, 117, 130),
  ...caption('x'),
  ...objFlags(0x08),
  ...close(0x1c),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
]);

/// A stacked case structure (`0x2c`) with three overlapping `0x1b` frames,
/// each holding one node at the same in-box spot, plus the given attribute
/// records on the structure itself.
ViModel stackedCaseModel(List<int> structAttrs) => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x2c, 10, tag: 0x1a),
  ...bounds(50, 50, 250, 250),
  ...structAttrs,
  ...open(0x1b, 11, tag: 0x1b),
  ...open(0x12, 21, tag: 0x1c),
  ...bounds(60, 60, 90, 90),
  ...close(0x1c),
  ...close(0x1b),
  ...open(0x1b, 12, tag: 0x1b),
  ...open(0x12, 22, tag: 0x1c),
  ...bounds(60, 60, 90, 90),
  ...close(0x1c),
  ...open(0x12, 32, tag: 0x1c),
  ...bounds(100, 100, 130, 130),
  ...close(0x1c),
  ...close(0x1b),
  ...open(0x1b, 13, tag: 0x1b),
  ...open(0x12, 23, tag: 0x1c),
  ...bounds(60, 60, 90, 90),
  ...close(0x1c),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
]);

Future<ui.Image> _tinyIcon() {
  final completer = Completer<ui.Image>();
  // 2x1: a black pixel and a transparent one.
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
    final data = (await remapped.toByteData())!.buffer.asUint8List();
    expect(data.sublist(0, 4), [0x77, 0x77, 0x77, 255]);
    expect(data[7], 0, reason: 'transparent pixel stays transparent');
  });

  group('bdHiddenFrameOids', () {
    test('the decoded index hides every other frame', () {
      final bd = stackedCaseModel([0x24, 0x4d, 0x02]).blockDiagrams.first;
      final hidden = bdHiddenFrameOids(bd);
      expect(hidden.contains(11), isTrue);
      expect(hidden.contains(12), isTrue);
      expect(
        hidden.contains(13),
        isFalse,
        reason: 'dIdx=2 keeps the third frame',
      );
    });

    test('an absent record displays the first frame', () {
      final hidden = bdHiddenFrameOids(
        stackedCaseModel(const []).blockDiagrams.first,
      );
      expect(hidden.contains(11), isFalse);
      expect(hidden.contains(12), isTrue);
      expect(hidden.contains(13), isTrue);
    });

    test('an out-of-range index falls through to the content heuristic', () {
      final hidden = bdHiddenFrameOids(
        stackedCaseModel([0x24, 0x4d, 0x09]).blockDiagrams.first,
      );
      expect(
        hidden.contains(12),
        isFalse,
        reason: 'the heuristic keeps the frame with most in-box content',
      );
      expect(hidden.contains(11), isTrue);
      expect(hidden.contains(13), isTrue);
    });
  });

  test('inlined subVI connector controls are excluded; bare constants kept', () {
    final diagram = modelWithInlinedSubViControl().blockDiagrams.first;
    final oids = bdDrawableObjects(diagram).map((o) => o.oid).toSet();
    // The named 0x51 connector-pane control (spliced from an inlined subVI) is
    // not this diagram's top-level object and is dropped from the drawn set.
    expect(oids, isNot(contains(5)));
    // The bare unnamed numeric constant is a real diagram object and is kept.
    expect(oids, contains(7));
  });

  test(
    'a numeric constant with a hidden name label is kept, not treated as inlined',
    () {
      // The exclusion keys on a *visible* connector-pane name; a diagram
      // constant's own name is hidden by default, so the decoded scalar caption
      // must not delete the constant (regression: `x`/`y` constants).
      final diagram = modelWithHiddenLabeledConstant().blockDiagrams.first;
      final namePart = diagram.byId[4]!;
      expect(
        namePart.label,
        'x',
        reason: 'the scalar caption is decoded on the name part',
      );
      expect(namePart.isLabelHidden, isTrue, reason: 'the name part is hidden');
      expect(bdDrawableObjects(diagram).map((o) => o.oid), contains(3));
    },
  );

  test('terminals keep LabVIEW datatype colors; unknown stays neutral', () {
    const rows = {
      ViTypeKind.numericFloat: Color(0xFFFF6600),
      // Sampled from LabVIEW's own snippet renders.
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

  test(
    'nodeDisplayLabel prefers a real name, hints from the class catalog',
    () {
      final named = heapObj(0x31, cat: ViObjectKind.node, label: 'Do Thing.vi');
      expect(nodeDisplayLabel(named), (text: 'Do Thing.vi', isHint: false));
      final bare = heapObj(0x2f, cat: ViObjectKind.node);
      expect(nodeDisplayLabel(bare).isHint, isTrue);
      expect(nodeDisplayLabel(bare).text, isNotEmpty);
    },
  );

  test('structureBadge names catalogued structures, hedges unknown ones', () {
    expect(structureBadge(heapObj(0x2c)), 'Case structure');
    expect(structureBadge(heapObj(0x7523)), 'Structure');
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
