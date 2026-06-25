import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/faithful_controls.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

ViHeapObject _obj({String? help, double? min, double? max}) =>
    ViHeapObject(oid: 1, kind: 0x50, offset: 0)
      ..helpText = help
      ..controlMin = min
      ..controlMax = max;

void main() {
  group('controlTooltip', () {
    test('help only', () => expect(controlTooltip(_obj(help: 'hover me')), 'hover me'));
    test('range only', () => expect(controlTooltip(_obj(min: -5, max: 10)), 'range: -5 … 10'));
    test('help + range joined', () =>
        expect(controlTooltip(_obj(help: 'doc', min: 0, max: 1)), 'doc\nrange: 0 … 1'));
    test('neither -> null', () => expect(controlTooltip(_obj()), isNull));
    test('NaN/blank suppressed', () {
      expect(controlTooltip(_obj(min: 0, max: double.nan)), isNull); // untrustworthy range, no help
      expect(controlTooltip(_obj(help: '   ')), isNull); // whitespace-only help
    });
    test('node falls back to its name, then its class label', () {
      final named = ViHeapObject(oid: 1, kind: 0x2f, offset: 0) // a BD node
        ..category = ViObjectKind.node
        ..label = 'Build Array';
      expect(controlTooltip(named), 'Build Array'); // propagated node name
      final nameless = ViHeapObject(oid: 2, kind: 0x2f, offset: 0)..category = ViObjectKind.node;
      expect(controlTooltip(nameless), 'Node (primitive)'); // class label when no name
    });
  });

  testWidgets('faithful control with a decoded range is wrapped in a range Tooltip', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctl = ViHeapObject(oid: 2, kind: 0x50, offset: 0) // a numeric control
      ..absBounds = const HeapRect(top: 10, left: 10, bottom: 40, right: 120)
      ..controlMin = -1
      ..controlMax = 1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FaithfulLayer(objects: [ctl], origin: Offset.zero, size: const Size(200, 200)),
      ),
    ));
    await tester.pump();
    expect(find.byTooltip('range: -1 … 1'), findsOneWidget); // tooltip exists without hovering
  });

  testWidgets('faithful controls do not overflow at tiny real-world bounds', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Real VIs place controls at small pixel bounds; a folder icon / spinner that
    // is wider than the control box used to overflow its Row (RenderFlex stripes).
    HeapRect tiny(int i) => HeapRect(top: i * 8, left: 0, bottom: i * 8 + 6, right: 8); // 8×6 px
    final objs = [
      ViHeapObject(oid: 1, kind: 0x50, offset: 0)..absBounds = tiny(0), // numeric (spinner)
      ViHeapObject(oid: 2, kind: 0x5b, offset: 0)..absBounds = tiny(1), // path (folder icon)
      ViHeapObject(oid: 3, kind: 0x57, offset: 0) // enum/ring (dropdown caret)
        ..absBounds = tiny(2)
        ..items = ['Alpha', 'Beta'],
      ViHeapObject(oid: 4, kind: 0x51, offset: 0)..absBounds = tiny(3), // string field
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: objs, origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull); // no RenderFlex overflow at tiny bounds
  });

  testWidgets('block-diagram kinds render a non-empty faithful widget (not SizedBox.shrink)', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Guards the BD classification work: these kinds were unclassified and rendered
    // as nothing; they must now route to real widgets (node/structure/leaf/label/glyph).
    HeapRect box(int i) => HeapRect(top: i * 40, left: 0, bottom: i * 40 + 32, right: 60);
    final objs = [
      ViHeapObject(oid: 1, kind: 0x2f, offset: 0)..absBounds = box(0), // node
      ViHeapObject(oid: 2, kind: 0x31, offset: 0)..absBounds = box(1), // named node
      ViHeapObject(oid: 3, kind: 0x16, offset: 0)..absBounds = box(2), // terminal/constant leaf
      ViHeapObject(oid: 4, kind: 0x2c, offset: 0)..absBounds = box(3), // structure frame
      ViHeapObject(oid: 5, kind: 0x95, offset: 0) // case selector label
        ..absBounds = box(4)
        ..label = 'True',
      ViHeapObject(oid: 6, kind: 0x177, offset: 0)..absBounds = box(5), // glyph
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: objs, origin: Offset.zero, size: const Size(800, 800))),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('True'), findsOneWidget); // 0x95 selector label text is drawn
    // The four box kinds each paint a Container (node/structure/leaf); none collapse
    // to SizedBox.shrink — a revert to the old empty render would drop these.
    expect(find.byType(Container), findsWidgets);
  });

  group('nodeDisplayLabel', () {
    test('a named node returns its name (not a hint)', () {
      final n = ViHeapObject(oid: 1, kind: 0x12, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'MySubVI.vi';
      final r = nodeDisplayLabel(n);
      expect(r.text, 'MySubVI.vi');
      expect(r.isHint, isFalse);
    });
    test('an unlabeled primitive returns a class hint', () {
      final n = ViHeapObject(oid: 1, kind: 0x2f, offset: 0)..category = ViObjectKind.node; // Node (primitive)
      final r = nodeDisplayLabel(n);
      expect(r.text, 'primitive'); // extracted from "Node (primitive)"
      expect(r.isHint, isTrue);
    });
    test('a qualifier-paren class keeps its full label (no misleading fragment)', () {
      // 0x12 = "Content group (FP)": the parens are a section qualifier, not a kind,
      // so the hint must be the full label, never "FP".
      final n = ViHeapObject(oid: 1, kind: 0x12, offset: 0)..category = ViObjectKind.node;
      final r = nodeDisplayLabel(n);
      expect(r.text, isNot('FP'));
      expect(r.text, n.objectClass.label); // full catalog label
    });
  });

  testWidgets('an unlabeled primitive node shows its class hint (not a blank box)', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prim = ViHeapObject(oid: 1, kind: 0x2f, offset: 0)
      ..category = ViObjectKind.node
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 40, right: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [prim], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    expect(find.text('primitive'), findsOneWidget);
  });

  testWidgets('a subVI node is an icon placeholder; name via tooltip, not double-printed', (tester) async {
    // The recovered name already renders on the canvas as the node's own floating
    // 0xa label, so the box must NOT re-print it (that would double-print). The
    // name stays reachable via tooltip on the icon placeholder.
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final node = ViHeapObject(oid: 1, kind: 0x2f, offset: 0)
      ..category = ViObjectKind.node
      ..absBounds = const HeapRect(top: 10, left: 10, bottom: 60, right: 160)
      ..label = 'PicoScope2000aOpen.vi';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [node], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    // No in-box name text...
    expect(find.text('PicoScope2000aOpen.vi'), findsNothing);
    // ...but the name is reachable via the tooltip on the placeholder.
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == 'PicoScope2000aOpen.vi'),
      findsOneWidget,
    );
  });

  testWidgets('noise objects are dimmed while logic objects stay full strength', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final node = ViHeapObject(oid: 1, kind: 0x2f, offset: 0)
      ..category = ViObjectKind.node
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 40, right: 120)
      ..label = 'MySubVI.vi';
    final decoration = ViHeapObject(oid: 2, kind: 0x88, offset: 0)
      ..category = ViObjectKind.decoration
      ..absBounds = const HeapRect(top: 60, left: 0, bottom: 100, right: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [node, decoration], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();

    // the decoration is dimmed (wrapped in an Opacity < 1); the named node is not
    final opacities = tester.widgetList<Opacity>(find.byType(Opacity)).map((w) => w.opacity).toList();
    expect(opacities.any((o) => o < 1.0), isTrue, reason: 'decoration should be dimmed');
    // logic node stays present and legible (its name is reachable via tooltip; the
    // name itself renders on-canvas as the node's own floating 0xa label, not in-box)
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == 'MySubVI.vi'),
      findsOneWidget,
    );
  });

  testWidgets('front panel renders everything at full strength (no de-emphasis dimming)', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // the same noise objects that get dimmed on the BD must NOT be dimmed on the FP
    // (a panel is a solid UI, not a logic graph).
    final decoration = ViHeapObject(oid: 1, kind: 0x88, offset: 0)
      ..category = ViObjectKind.decoration
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 40, right: 120);
    final unknown = ViHeapObject(oid: 2, kind: 0x999, offset: 0)
      ..category = ViObjectKind.unknown
      ..absBounds = const HeapRect(top: 60, left: 0, bottom: 100, right: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FaithfulLayer(
            objects: [decoration, unknown], origin: Offset.zero, size: const Size(400, 400), isFrontPanel: true),
      ),
    ));
    await tester.pump();

    final opacities = tester.widgetList<Opacity>(find.byType(Opacity)).map((w) => w.opacity).toList();
    expect(opacities.any((o) => o < 1.0), isFalse, reason: 'FP objects must not be dimmed');
  });

  test('structureBadge tracks the class catalog (honest, no fabrication)', () {
    ViHeapObject st(int kind) => ViHeapObject(oid: 1, kind: kind, offset: 0)..category = ViObjectKind.structure;
    // dedicated, confidently-classified structures surface their real kind
    expect(structureBadge(st(0x20)), 'For loop');
    expect(structureBadge(st(0x21)), 'While loop');
    expect(structureBadge(st(0x2c)), 'Case structure');
    // the dual-role 0x53 keeps the catalog's honest hedge (NOT a bare "Loop")
    expect(structureBadge(st(0x53)), 'Loop (BD) / container (FP)');
    // an uncatalogued structure falls back to the generic word
    final unknown = ViHeapObject(oid: 2, kind: 0x4242, offset: 0)..category = ViObjectKind.structure;
    expect(structureBadge(unknown), 'Structure');
  });

  testWidgets('a While-loop structure shows its catalog kind badge', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final loop = ViHeapObject(oid: 1, kind: 0x21, offset: 0) // HeapObjectClass.bdWhileLoop
      ..category = ViObjectKind.structure
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 200, right: 200);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [loop], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    expect(find.text('While loop'), findsOneWidget);
  });

  testWidgets('a single-item 0x4f renders as a LABELED BOOLEAN, not a 1-option dropdown', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 0x4f with one 0x0d string = the boolean's caption (e.g. STOP / Channel A),
    // NOT an enum choice — it must render as a labeled boolean, no dropdown caret.
    final boolCtl = ViHeapObject(oid: 1, kind: 0x4f, offset: 0) // booleanOrClusterControl
      ..category = ViObjectKind.terminal
      ..items = ['STOP']
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 30, right: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [boolCtl], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    expect(find.text('STOP'), findsOneWidget); // caption shown on the boolean
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing); // not a ring/dropdown
  });

  testWidgets('a 0x4f with >= 2 items still renders as a ring/dropdown', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ring = ViHeapObject(oid: 1, kind: 0x4f, offset: 0)
      ..category = ViObjectKind.terminal
      ..items = ['Level', 'Window']
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 30, right: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [ring], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget); // >= 2 items -> dropdown
  });

  testWidgets('a control sub-part (0x0b) renders as faint scaffolding, not a control box', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 0x0b is an internal part (numeric spinner arrows / boolean glyph) of its
    // parent control — it must not masquerade as a standalone control-blue box.
    final sub = ViHeapObject(oid: 1, kind: 0x0b, offset: 0)
      ..category = ViObjectKind.terminal
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 17, right: 6);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [sub], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();

    BoxDecoration? deco(Widget w) => w is Container && w.decoration is BoxDecoration ? w.decoration as BoxDecoration : null;
    // faint scaffolding (translucent), NOT the generic control-blue fill 0xFFE3ECF5
    expect(find.byWidgetPredicate((w) => deco(w)?.color == const Color(0x11000000)), findsOneWidget);
    expect(find.byWidgetPredicate((w) => deco(w)?.color == const Color(0xFFE3ECF5)), findsNothing);
  });

  testWidgets('a graph exposes recovered plot names via tooltip, not a painted legend', (tester) async {
    // The file already carries the real plot legend as its own positioned
    // decoration object; we must NOT paint a second one at an invented spot.
    // Recovered names are surfaced only as a tooltip (an inspector affordance).
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final graph = ViHeapObject(oid: 1, kind: 0x5e, offset: 0) // graphIndicator
      ..category = ViObjectKind.terminal
      ..plotNames = ['Plot 0', 'Plot 1']
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 200, right: 300);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FaithfulLayer(objects: [graph], origin: Offset.zero, size: const Size(400, 400))),
    ));
    await tester.pump();
    // No painted legend text on the canvas...
    expect(find.text('Plot 0'), findsNothing);
    // ...but the names are recoverable via the tooltip.
    final tip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tip.message, contains('Plot 0'));
    expect(tip.message, contains('Plot 1'));
  });

  group('structureFrameTitle', () {
    ViHeapObject cluster({String? label}) => ViHeapObject(oid: 1, kind: 0x64, offset: 0) // clusterShell
      ..category = ViObjectKind.structure
      ..label = label;
    test('block diagram: shows the catalog kind badge', () {
      expect(structureFrameTitle(cluster(), isFrontPanel: false), 'Cluster/array shell');
      expect(structureFrameTitle(cluster(label: 'Channel B Settings'), isFrontPanel: false), 'Cluster/array shell');
    });
    test('front panel: shows the own caption, never the class-kind badge', () {
      // a captioned FP container shows ITS caption, not "Cluster/array shell"
      expect(structureFrameTitle(cluster(label: 'Channel B Settings'), isFrontPanel: true), 'Channel B Settings');
      // an uncaptioned FP container shows nothing (so it can't obscure a sibling label)
      expect(structureFrameTitle(cluster(), isFrontPanel: true), isNull);
      expect(structureFrameTitle(cluster(label: '   '), isFrontPanel: true), isNull);
    });
  });

  testWidgets('FP container does not stamp its class-kind badge over the caption', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final clusterBox = ViHeapObject(oid: 1, kind: 0x64, offset: 0) // Cluster/array shell
      ..category = ViObjectKind.structure
      ..label = 'Channel B Settings'
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 200, right: 200);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FaithfulLayer(objects: [clusterBox], origin: Offset.zero, size: const Size(400, 400), isFrontPanel: true),
      ),
    ));
    await tester.pump();
    expect(find.text('Cluster/array shell'), findsNothing); // badge suppressed on FP
    expect(find.text('Channel B Settings'), findsOneWidget); // caption shown instead
  });
}
