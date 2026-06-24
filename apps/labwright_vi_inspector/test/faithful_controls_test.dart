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

  testWidgets('a subVI node renders its recovered name on the box', (tester) async {
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
    expect(find.text('PicoScope2000aOpen.vi'), findsOneWidget);
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
    expect(find.text('MySubVI.vi'), findsOneWidget); // logic stays legible
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
}
