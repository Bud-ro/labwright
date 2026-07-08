import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/faithful_controls.dart';

import 'util.dart';

Future<void> pumpLayer(
  WidgetTester tester,
  List<ViHeapObject> objects, {
  bool fp = false,
  Size size = const Size(400, 400),
}) => pumpBody(
  tester,
  FaithfulLayer(
    objects: objects,
    origin: Offset.zero,
    size: size,
    isFrontPanel: fp,
  ),
  view: const Size(800, 800),
);

List<double> opacities(WidgetTester tester) => [
  for (final w in tester.widgetList<Opacity>(find.byType(Opacity))) w.opacity,
];

Finder tooltipWith(String message) =>
    find.byWidgetPredicate((w) => w is Tooltip && w.message == message);

void main() {
  test(
    'controlTooltip joins help + range; suppresses NaN/blank; node names',
    () {
      ViHeapObject ctl({String? help, double? min, double? max}) =>
          heapObj(0x50, help: help, min: min, max: max);
      final rows = <(String, ViHeapObject, String?)>[
        ('help only', ctl(help: 'hover me'), 'hover me'),
        ('range only', ctl(min: -5, max: 10), 'range: -5 … 10'),
        ('help + range', ctl(help: 'doc', min: 0, max: 1), 'doc\nrange: 0 … 1'),
        ('no help or range', ctl(), null),
        ('NaN bound suppressed', ctl(min: 0, max: double.nan), null),
        ('blank help suppressed', ctl(help: '   '), null),
        (
          'named node',
          heapObj(0x2f, cat: ViObjectKind.node, label: 'Build Array'),
          'Build Array',
        ),
        (
          'unnamed node',
          heapObj(0x2f, oid: 2, cat: ViObjectKind.node),
          'Node (primitive)',
        ),
      ];
      for (final (name, o, want) in rows) {
        expect(controlTooltip(o), want, reason: name);
      }
    },
  );

  test('nodeDisplayLabel: name beats hint; qualifier parens stay whole', () {
    final named = nodeDisplayLabel(
      heapObj(0x12, cat: ViObjectKind.node, label: 'MySubVI.vi'),
    );
    expect((named.text, named.isHint), ('MySubVI.vi', false));
    final prim = nodeDisplayLabel(heapObj(0x2f, cat: ViObjectKind.node));
    expect((prim.text, prim.isHint), ('primitive', true));
    // 0x12 = "Content group (FP)": parens are a section qualifier, not a
    // kind, so the hint is the full label — never a "FP" fragment.
    final grp = nodeDisplayLabel(heapObj(0x12, cat: ViObjectKind.node));
    expect(grp.text, isNot('FP'));
    expect(grp.text, heapObj(0x12).objectClass.label);
  });

  test('structureBadge tracks the class catalog (no fabrication)', () {
    const rows = {
      0x20: 'For loop',
      0x21: 'While loop',
      0x2c: 'Case structure',
      0x53: 'Loop (BD) / container (FP)',
      0x4242: 'Structure',
    };
    rows.forEach(
      (kind, want) => expect(
        structureBadge(heapObj(kind, cat: ViObjectKind.structure)),
        want,
      ),
    );
  });

  test('structureFrameTitle: BD shows kind badge, FP shows own caption', () {
    ViHeapObject cluster({String? label}) =>
        heapObj(0x64, cat: ViObjectKind.structure, label: label);
    final rows = <(String, ViHeapObject, bool, String?)>[
      ('BD, no caption', cluster(), false, 'Cluster/array shell'),
      (
        'BD, caption ignored',
        cluster(label: 'Channel B Settings'),
        false,
        'Cluster/array shell',
      ),
      (
        'FP, caption shown',
        cluster(label: 'Channel B Settings'),
        true,
        'Channel B Settings',
      ),
      ('FP, no caption', cluster(), true, null),
      ('FP, blank caption', cluster(label: '   '), true, null),
    ];
    for (final (name, o, fp, want) in rows) {
      expect(structureFrameTitle(o, isFrontPanel: fp), want, reason: name);
    }
  });

  group('faithful rendering', () {
    // (name, objects, isFrontPanel, exact texts seen, texts never seen)
    final rows =
        <(String, List<ViHeapObject>, bool, List<String>, List<String>)>[
          (
            'a While-loop structure shows its catalog kind badge',
            [heapObj(0x21, cat: ViObjectKind.structure, at: (0, 0, 200, 200))],
            false,
            ['While loop'],
            [],
          ),
          (
            'an unlabeled primitive node shows its class hint, not a blank box',
            [heapObj(0x2f, cat: ViObjectKind.node, at: (0, 0, 40, 120))],
            false,
            ['primitive'],
            [],
          ),
          (
            'an FP container shows its caption, never its class-kind badge',
            [
              heapObj(
                0x64,
                cat: ViObjectKind.structure,
                label: 'Channel B Settings',
                at: (0, 0, 200, 200),
              ),
            ],
            true,
            ['Channel B Settings'],
            ['Cluster/array shell'],
          ),
        ];
    for (final (name, objs, fp, sees, nevers) in rows) {
      testWidgets(name, (tester) async {
        await pumpLayer(tester, objs, fp: fp);
        for (final t in sees) {
          expect(find.text(t), findsOneWidget, reason: t);
        }
        for (final t in nevers) {
          expect(find.text(t), findsNothing, reason: t);
        }
      });
    }
  });

  testWidgets(
    'a single-item 0x4f renders as a labeled boolean, not a dropdown',
    (tester) async {
      await pumpLayer(tester, [
        heapObj(
          0x4f,
          cat: ViObjectKind.terminal,
          items: ['STOP'],
          at: (0, 0, 30, 120),
        ),
      ]);
      expect(find.text('STOP'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    },
  );

  testWidgets('a 0x4f with >= 2 items still renders as a ring/dropdown', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(
        0x4f,
        cat: ViObjectKind.terminal,
        items: ['Level', 'Window'],
        at: (0, 0, 30, 120),
      ),
    ]);
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
  });

  testWidgets('a decoded range wraps the control in a range Tooltip', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(0x50, oid: 2, at: (10, 10, 40, 120), min: -1, max: 1),
    ], size: const Size(200, 200));
    expect(find.byTooltip('range: -1 … 1'), findsOneWidget);
  });

  testWidgets('faithful controls do not overflow at tiny real-world bounds', (
    tester,
  ) async {
    (int, int, int, int) tiny(int i) => (i * 8, 0, i * 8 + 6, 8); // 8×6 px
    await pumpLayer(tester, [
      heapObj(0x50, at: tiny(0)), // numeric (spinner)
      heapObj(0x5b, oid: 2, at: tiny(1)), // path (folder icon)
      heapObj(0x57, oid: 3, at: tiny(2), items: ['Alpha', 'Beta']), // enum/ring
      heapObj(0x51, oid: 4, at: tiny(3)), // string field
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('block-diagram kinds render a non-empty faithful widget', (
    tester,
  ) async {
    (int, int, int, int) box(int i) => (i * 40, 0, i * 40 + 32, 60);
    await pumpLayer(tester, [
      heapObj(0x2f, at: box(0)), // node
      heapObj(0x31, oid: 2, at: box(1)), // named node
      heapObj(0x16, oid: 3, at: box(2)), // terminal/constant leaf
      heapObj(0x2c, oid: 4, at: box(3)), // structure frame
      heapObj(0x95, oid: 5, at: box(4), label: 'True'), // case selector label
      heapObj(0x177, oid: 6, at: box(5)), // glyph
    ], size: const Size(800, 800));
    expect(tester.takeException(), isNull);
    expect(find.text('True'), findsOneWidget);
    expect(find.byType(Container), findsWidgets);
  });

  testWidgets('a subVI node is an icon placeholder; name via tooltip only', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(
        0x2f,
        cat: ViObjectKind.node,
        label: 'PicoScope2000aOpen.vi',
        at: (10, 10, 60, 160),
      ),
    ]);
    expect(find.text('PicoScope2000aOpen.vi'), findsNothing);
    expect(tooltipWith('PicoScope2000aOpen.vi'), findsOneWidget);
  });

  testWidgets('BD: noise objects are dimmed, logic stays full strength', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(
        0x2f,
        cat: ViObjectKind.node,
        label: 'MySubVI.vi',
        at: (0, 0, 40, 120),
      ),
      heapObj(
        0x88,
        oid: 2,
        cat: ViObjectKind.decoration,
        at: (60, 0, 100, 120),
      ),
    ]);
    expect(
      opacities(tester).any((o) => o < 1.0),
      isTrue,
      reason: 'decoration should be dimmed',
    );
    expect(tooltipWith('MySubVI.vi'), findsOneWidget);
  });

  testWidgets('FP renders everything at full strength (no dimming)', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(0x88, cat: ViObjectKind.decoration, at: (0, 0, 40, 120)),
      heapObj(0x999, oid: 2, cat: ViObjectKind.unknown, at: (60, 0, 100, 120)),
    ], fp: true);
    expect(
      opacities(tester).any((o) => o < 1.0),
      isFalse,
      reason: 'FP objects must not be dimmed',
    );
  });

  testWidgets('a control sub-part (0x0b) renders as faint scaffolding', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(0x0b, cat: ViObjectKind.terminal, at: (0, 0, 17, 6)),
    ]);
    BoxDecoration? deco(Widget w) =>
        w is Container && w.decoration is BoxDecoration
        ? w.decoration as BoxDecoration
        : null;
    expect(
      find.byWidgetPredicate((w) => deco(w)?.color == const Color(0x11000000)),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) => deco(w)?.color == const Color(0xFFE3ECF5)),
      findsNothing,
    );
  });

  testWidgets('a graph exposes plot names via tooltip, not a painted legend', (
    tester,
  ) async {
    await pumpLayer(tester, [
      heapObj(
        0x5e,
        cat: ViObjectKind.terminal,
        plotNames: ['Plot 0', 'Plot 1'],
        at: (0, 0, 200, 300),
      ),
    ]);
    expect(find.text('Plot 0'), findsNothing);
    final tip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tip.message, contains('Plot 0'));
    expect(tip.message, contains('Plot 1'));
  });
}
