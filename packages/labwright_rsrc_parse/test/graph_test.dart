import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Object/group open record: `10 <tag> 02 fe <u16 kind> fd <u16 oid>`.
List<int> open(int kind, int oid, {int tag = 0x19}) => [
  0x10,
  tag,
  0x02,
  0xfe,
  kind >> 8,
  kind & 0xff,
  0xfd,
  oid >> 8,
  oid & 0xff,
];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) => [
  0xc4,
  0x2d,
  0x08,
  t >> 8,
  t & 0xff,
  l >> 8,
  l & 0xff,
  b >> 8,
  b & 0xff,
  r >> 8,
  r & 0xff,
];
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];
List<int> fmt74(String s) => [0xc4, 0x74, s.length, ...s.codeUnits];
List<int> enum2e(List<String> items) {
  final b = <int>[
    for (final it in items) ...[it.length, ...it.codeUnits],
  ];
  return [0xc4, 0x2e, b.length, ...b];
}

List<int> c6blob(int id, String s) => [
  0xc6,
  id,
  0xff,
  (4 + s.length) >> 8,
  (4 + s.length) & 0xff,
  0,
  0,
  0,
  s.length,
  ...s.codeUnits,
];

/// Description/help record: `C4 19 <len> <text>` — the genuine help/tooltip
/// source ([HeapRecord.descriptionText]).
List<int> help(String s) => [0xc4, 0x19, s.length, ...s.codeUnits];

void main() {
  test('bracket tree: parent/child nesting + absolute coordinates', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 500, 500),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(10, 20, 30, 40),
      ...caption('Trigger'),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final d = buildDiagram(body);

    expect(d.objects.length, 2);
    expect(d.roots.map((o) => o.oid), [1]);
    final child = d.byId[2]!;
    expect(child.parentOid, 1);
    expect(child.label, 'Trigger');
    expect(
      [child.absBounds!.top, child.absBounds!.left, child.absBounds!.bottom, child.absBounds!.right],
      [10, 20, 30, 40],
      reason: 'abs = parent origin (0,0) + local bounds',
    );
    expect(d.children(1).map((o) => o.oid), [2]);
  });

  test('absolute coordinates compose down the object-ancestor chain', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(100, 200, 900, 900),
      ...open(0x53, 2, tag: 0x1a),
      ...bounds(5, 5, 50, 50),
      ...open(0x50, 3, tag: 0x1b),
      ...bounds(1, 2, 11, 12),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final leaf = buildDiagram(body).byId[3]!;
    expect(
      [leaf.absBounds!.top, leaf.absBounds!.left],
      [106, 207],
      reason: 'abs composes down origins: top 100+5+1, left 200+5+2',
    );
  });

  test('structure child-membership refs attach to the structure, not terminals', () {
    final records = <int>[
      ...open(0x53, 1),
      ...bounds(0, 0, 100, 100),
      0x10,
      0x55,
      0x01,
      0xfb,
      0x00,
      0x02,
      0x14,
      0x19,
      0x01,
      0xfd,
      0x00,
      0x09,
      0x14,
      0x19,
      0x01,
      0xfd,
      0x00,
      0x0a,
      ...close(0x55),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final s = buildDiagram(body).byId[1]!;
    expect(s.category, ViObjectKind.structure);
    expect(s.refs, [9, 10]);
  });

  test('the full typed-ref family is collected (childRef + dcoRef + ddoRef) into the object graph', () {
    final records = <int>[
      ...open(0x53, 1),
      ...bounds(0, 0, 100, 100),
      0x14,
      0x19,
      0x01,
      0xfd,
      0x00,
      0x09,
      0x14,
      0x4f,
      0x01,
      0xfd,
      0x00,
      0x0b,
      0x14,
      0x50,
      0x01,
      0xfd,
      0x00,
      0x0c,
      0x14,
      0x53,
      0x01,
      0xfd,
      0x00,
      0x07,
      ...close(),
    ];
    final s = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records])).byId[1]!;
    expect(s.refs, [9], reason: 's.refs is the backward-compatible childRef subset');
    expect(s.typedRefs[HeapRefKind.childRef], [9]);
    expect(s.typedRefs[HeapRefKind.dcoRef], [11]);
    expect(s.typedRefs[HeapRefKind.dcoAggRef], [12]);
    expect(
      s.typedRefs[HeapRefKind.ddoRef],
      [7],
      reason: '14 53 is a cross-heap display-object reference (resolves in the sibling heap)',
    );
    expect(s.memberOids.toSet(), {9, 11}, reason: 'memberOids = childRef ∪ dcoRef');
  });

  test('classifies kinds and infers type from attached C4 records', () {
    final records = <int>[
      ...open(0x68, 1),
      ...bounds(0, 0, 17, 17),
      ...close(),
      ...open(0x12, 2),
      ...bounds(0, 0, 40, 40),
      ...close(),
      ...open(0x50, 3),
      ...bounds(0, 0, 17, 80),
      ...fmt74('%#_6g'),
      ...close(),
      ...open(0x50, 4),
      ...bounds(0, 0, 17, 80),
      ...fmt74('%04d'),
      ...close(),
      ...open(0x0d, 5),
      ...bounds(0, 0, 17, 80),
      ...enum2e(['Low', 'High']),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[1]!.category, ViObjectKind.terminal);
    expect(d.byId[2]!.category, ViObjectKind.node);
    expect(d.byId[3]!.typeKind, ViTypeKind.numericFloat);
    expect(d.byId[4]!.typeKind, ViTypeKind.numericInt);
    expect(d.byId[5]!.typeKind, ViTypeKind.enumRing);
  });

  test('scrolled-cluster control terminals are re-anchored to their viewport', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 500, 500),
      ...open(0x53, 2),
      ...bounds(200, 50, 400, 200),
      ...open(0x11c, 3),
      ...bounds(10, 5, 160, 130),
      ...open(0x50, 4),
      ...bounds(-300, 9, -256, 105),
      ...open(0xa, 6),
      ...bounds(0, 11, 17, 107),
      ...caption('Start'),
      ...close(),
      ...open(0x4f, 8),
      ...bounds(5, 10, 17, 30),
      ...close(),
      ...close(),
      ...open(0x50, 5),
      ...bounds(-262, 9, -218, 105),
      ...close(),
      ...close(),
      ...close(),
      ...open(0x50, 7),
      ...bounds(300, 300, 320, 350),
      ...close(),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    final vp = d.byId[3]!.absBounds!;
    final c4 = d.byId[4]!.absBounds!, c5 = d.byId[5]!.absBounds!;

    expect([c4.top, c4.left], [210, 55], reason: '#4 re-anchored to the viewport origin');
    expect(c5.top, 248, reason: '#5 sits 38px below #4 (-262 vs -300) -> 210+38');
    for (final c in [c4, c5]) {
      final cy = (c.top + c.bottom) ~/ 2;
      expect(cy >= vp.top && cy <= vp.bottom, isTrue, reason: 'control center inside viewport');
    }
    expect(d.byId[6]!.absBounds!.top, 210, reason: "#4's label subtree rides along with the re-anchor");
    expect(
      [d.byId[8]!.absBounds!.top, d.byId[8]!.absBounds!.left],
      [215, 65],
      reason: 'a control nested inside #4 rides along with its parent, not re-anchored to the viewport',
    );
    expect(
      [d.byId[7]!.absBounds!.top, d.byId[7]!.absBounds!.left],
      [300, 300],
      reason: 'a direct on-diagram terminal (not under a 0x11c) is left untouched',
    );
  });

  test('HeapObjectClass catalog: unique codes, round-trip, category agreement', () {
    final seen = <int>{};
    for (final c in HeapObjectClass.values) {
      if (c == HeapObjectClass.unknown) continue;
      expect(seen.add(c.code), isTrue, reason: 'duplicate code 0x${c.code.toRadixString(16)}');
      expect(HeapObjectClass.fromCode(c.code), c);
      expect(c.label, isNotEmpty);
    }
    expect(HeapObjectClass.fromCode(0xabcd), HeapObjectClass.unknown);
    expect(HeapObjectClass.fromCode(0x50).label, 'Numeric control');
    expect(classifyObject(kind: 0x68, termCount: 0), ViObjectKind.terminal);
    expect(classifyObject(kind: 0x12, termCount: 0), ViObjectKind.node);
    expect(classifyObject(kind: 0x53, termCount: 0), ViObjectKind.structure);
    expect(
      classifyObject(kind: 0x2f, termCount: 0),
      ViObjectKind.node,
      reason: 'newly catalogued block-diagram node (32×32 icon footprint under 0x1b)',
    );
    expect(
      classifyObject(kind: 0x31, termCount: 0),
      ViObjectKind.node,
      reason: 'newly catalogued block-diagram node (32×32 icon footprint under 0x1b)',
    );
    expect(classifyObject(kind: 0x16, termCount: 0), ViObjectKind.terminal, reason: '0x16 = free-standing BD leaf');
    expect(classifyObject(kind: 0x2c, termCount: 0), ViObjectKind.structure, reason: '0x2c = BD structure frame');
    expect(classifyObject(kind: 0x95, termCount: 0), ViObjectKind.terminal, reason: '0x95 = case selector label');
    expect(classifyObject(kind: 0x177, termCount: 0), ViObjectKind.decoration, reason: '0x177 = node glyph');
    expect(classifyObject(kind: 0x63, termCount: 0), ViObjectKind.node, reason: '0x63 = growable node');
    for (final k in [
      0x8c,
      0x3a,
      0xd6,
      0x32,
      0xc5,
      0x104,
      0x44,
      0x3e,
      0x34,
      0xa9,
      0x93,
      0x172,
      0x6c,
      0x36,
      0x153,
      0x6a,
      0xbd,
      0x114,
      0xb6,
      0xb9,
      0x48,
      0xeb,
      0x103,
      0x14a,
    ]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.node, reason: 'BD nodes (caption- or icon-confirmed)');
    }
    for (final k in [0x55, 0x4e, 0x10c, 0xc2]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.terminal, reason: 'control terminal / constant');
    }
    for (final k in [0xca, 0x29, 0xd5, 0x121]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.structure, reason: 'sequence/event/frame structures');
    }
    for (final k in [0x20, 0x21, 0xcd, 0x14d]) {
      expect(
        classifyObject(kind: k, termCount: 0),
        ViObjectKind.structure,
        reason: 'loop/case/disable/in-place frames',
      );
    }
    expect(
      classifyObject(kind: 0x50, termCount: 2),
      ViObjectKind.terminalCluster,
      reason: 'the C4-1F terminal signal still wins over the catalog category',
    );
  });

  test('section-dependent class labels stay honest about what was observed', () {
    final loop = HeapObjectClass.fromCode(0x53).label;
    expect(loop, contains('(BD)'), reason: '0x53 is genuinely dual-role: BD loops + FP containers');
    expect(loop, contains('(FP)'));
    expect(
      loop,
      isNot('Loop (while/for)'),
      reason: 'a section-blind label would mislabel the FP-container occurrences',
    );
    for (final code in [0x12, 0x4c]) {
      final label = HeapObjectClass.fromCode(code).label;
      expect(label, contains('(FP)'), reason: '0x${code.toRadixString(16)} lost its FP-role tag');
      expect(label, isNot(contains('(BD)')), reason: '0x${code.toRadixString(16)} re-asserts an unobserved BD role');
    }
    final c52 = HeapObjectClass.fromCode(0x52).label;
    expect(c52, isNot(contains('case')));
    expect(c52, isNot(contains('Case')));
  });

  test('enum/ring items are parsed and propagated up to the enclosing control', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x57, 2, tag: 0x1a),
      ...bounds(10, 10, 30, 110),
      ...open(0x0d, 3, tag: 0x1b),
      ...bounds(12, 12, 28, 100),
      ...enum2e(['Low', 'Med', 'High']),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.items, ['Low', 'Med', 'High']);
    expect(
      d.byId[2]!.items,
      ['Low', 'Med', 'High'],
      reason: 'items propagate up from the 0x0d item-list to the enclosing 0x57 control (used by faithful mode)',
    );
  });

  test('graph plot names (C4 27) attach to the 0x5E graph object', () {
    List<int> plot(String s) => [0xc4, 0x27, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x5e, 2, tag: 0x1a),
      ...bounds(10, 10, 200, 300),
      ...plot('Plot 0'),
      ...plot('Plot 1'),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[2]!.plotNames, ['Plot 0', 'Plot 1'], reason: 'recovered in heap order');
    expect(d.byId[1]!.plotNames, isEmpty, reason: 'plot names attach to the graph, not the root');
  });

  test('enum item parsing rejects the WHOLE table on overrun or non-printable bytes', () {
    List<int> rawEnum(List<int> payload) => [0xc4, 0x2e, payload.length, ...payload];
    List<int> build(List<int> enumRec) {
      final records = <int>[
        ...open(0x7e, 1),
        ...bounds(0, 0, 100, 100),
        ...open(0x0d, 2, tag: 0x1b),
        ...bounds(0, 0, 17, 80),
        ...enumRec,
        ...close(0x1b),
        ...close(),
      ];
      return [0, 0, 0, records.length, ...records];
    }

    final overrun = buildDiagram(Uint8List.fromList(build(rawEnum([0x0a, 0x41, 0x42, 0x43]))));
    expect(
      overrun.byId[2]!.items,
      isEmpty,
      reason: 'first item claims length 10 but only 3 bytes follow -> overrun -> reject all',
    );
    final nonPrintable = buildDiagram(Uint8List.fromList(build(rawEnum([0x03, 0x41, 0x00, 0x43]))));
    expect(
      nonPrintable.byId[2]!.items,
      isEmpty,
      reason: 'an embedded non-printable byte (0x00) rejects the whole table',
    );
  });

  test('control range (0x20/0x21) + help (0x6C FF) collected ONLY on controls, not decorations', () {
    List<int> f64rec(int id, double v) {
      // C6 form: raw 0x220/0x221 = stdNumMin/stdNumMax (the corpus carrier).
      final d = ByteData(8)..setFloat64(0, v);
      return [0xc6, id, 0x08, ...d.buffer.asUint8List()];
    }

    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(0, 0, 17, 80),
      ...f64rec(0x20, -5.0),
      ...f64rec(0x21, 10.0),
      ...help('a tooltip'),
      ...close(0x1a),
      ...open(0x8f, 3, tag: 0x1b),
      ...bounds(0, 0, 10, 10),
      ...f64rec(0x20, 1.0),
      ...f64rec(0x21, -1.0),
      ...close(0x1b),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    final ctl = d.byId[2]!, deco = d.byId[3]!;
    expect(ctl.controlMin, -5.0);
    expect(ctl.controlMax, 10.0);
    expect(ctl.helpText, 'a tooltip');
    expect(deco.controlMin, isNull, reason: 'range must not attach to a 0x8f decoration (non-control)');
    expect(deco.controlMax, isNull);
  });

  test('help text propagates up from a non-drawable child to its nearest drawable control', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(10, 10, 30, 100),
      ...open(0xc1, 3, tag: 0x1b),
      ...help('hover help'),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.absBounds, isNull, reason: 'the 0xc1 tip-strip carries help but is not drawable');
    expect(d.byId[2]!.helpText, 'hover help', reason: 'help propagates up to the drawn control');
  });

  test('help propagation skips a non-drawable intermediate to reach the nearest drawable', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(10, 10, 30, 100),
      ...open(0x0c, 3, tag: 0x1b),
      ...open(0xc1, 4, tag: 0x1c),
      ...help('deep help'),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.absBounds, isNull, reason: 'the 0x0c intermediate (terminal cluster) is not drawn');
    expect(d.byId[3]!.helpText, isNull, reason: 'help does not land on the skipped non-drawable intermediate');
    expect(d.byId[2]!.helpText, 'deep help', reason: 'help reaches the nearest drawable ancestor');
  });

  test('help propagation lands on a 0x53 structure when that is the nearest drawable ancestor', () {
    final records = <int>[
      ...open(0x53, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0xc1, 2, tag: 0x1a),
      ...help('structure help'),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[1]!.helpText, 'structure help', reason: 'a 0x53 structure can legitimately own help too');
  });

  test('help propagation never overwrites an ancestor that already carries its own help (??=)', () {
    final records = <int>[
      ...open(0x50, 1),
      ...bounds(10, 10, 30, 100),
      ...help('own help'),
      ...open(0xc1, 2, tag: 0x1a),
      ...help('child help'),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(
      d.byId[1]!.helpText,
      'own help',
      reason: "first-wins (??=): the control's own help is preserved over a child's",
    );
  });

  test('structural node fallback: an unknown drawable kind under 0x1b with only 0x15 children -> node', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x1b, 2, tag: 0x1a),
      ...open(0x150, 3, tag: 0x1b),
      ...bounds(10, 10, 42, 42),
      ...open(0x15, 4, tag: 0x1c),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.objectClass, HeapObjectClass.unknown, reason: '0x150 is not catalogued by code');
    expect(
      d.byId[3]!.category,
      ViObjectKind.node,
      reason: 'an uncatalogued drawable under 0x1b with only 0x15 children classifies as a node',
    );
  });

  test('a BD node inherits its name from its child 0xa caption (for details/tooltip)', () {
    final records = <int>[
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x2f, 2, tag: 0x1a),
      ...bounds(10, 10, 42, 42),
      ...open(0xa, 3, tag: 0x1b),
      ...caption('Build Array'),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.label, 'Build Array', reason: 'the child 0xa carries the C4 22 caption');
    expect(d.byId[2]!.label, 'Build Array', reason: 'the caption propagates up to name the 0x2f node');
  });

  test('a constValue string (C6 6C FF blob) becomes constText, never helpText', () {
    final records = <int>[
      ...open(0x50, 1),
      ...bounds(0, 0, 17, 80),
      ...c6blob(0x6c, 'ps2000aRunStreaming'),
      ...close(),
    ];
    final o = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records])).byId[1]!;
    expect(o.constText, 'ps2000aRunStreaming', reason: 'raw 0x26C is a BD string constant value, not help');
    expect(o.helpText, isNull, reason: 'a constant value must not be mislabeled as help/description text');
  });

  test('a 0x6C <u8 len> token is captured by neither constText nor helpText', () {
    List<int> u8tok(String s) => [0xc6, 0x6c, 4 + s.length, 0, 0, 0, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x50, 1),
      ...bounds(0, 0, 17, 80),
      ...u8tok('ps2000aRunStreaming'),
      ...close(),
    ];
    final o = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records])).byId[1]!;
    expect(o.helpText, isNull);
    expect(
      o.constText,
      isNull,
      reason: 'buildDiagram captures only the C6 6C FF blob form of constValue, not the <u8 len> form',
    );
  });

  test('formatControlRange renders honestly (finite-only, inverted/±∞/NaN suppressed)', () {
    expect(formatControlRange(-5.0, 10.0), '-5 … 10');
    expect(formatControlRange(0.0, 2.5), '0 … 2.5');
    expect(formatControlRange(5.0, double.infinity), '≥ 5', reason: '+∞ max -> one-sided');
    expect(formatControlRange(double.negativeInfinity, 10.0), '≤ 10');
    expect(formatControlRange(double.negativeInfinity, double.infinity), isNull, reason: 'both ±∞ -> nothing');
    expect(formatControlRange(null, null), isNull);
    expect(formatControlRange(1.0, -1.0), isNull, reason: 'inverted finite pair -> nothing');
    expect(formatControlRange(5.0, 5.0), isNull, reason: 'degenerate equal pair -> noise, not a range');
    expect(formatControlRange(0.0, -0.0), isNull, reason: '0 vs -0.0 (lo >= hi) -> nothing');
    expect(formatControlRange(0.0, double.nan), isNull, reason: 'NaN max -> untrustworthy pair');
    expect(formatControlRange(double.nan, 10.0), isNull);
  });

  test('stripHelpMarkup removes LabVIEW markup tags for display but keeps real text', () {
    expect(stripHelpMarkup('<B>error out</B> contains error information.'), 'error out contains error information.');
    expect(stripHelpMarkup('<B>code</B> is 0.'), 'code is 0.');
    expect(stripHelpMarkup('line one\n<I>line</I> two'), 'line one\nline two', reason: 'newlines kept');
    expect(stripHelpMarkup('plain help, no tags'), 'plain help, no tags');
    expect(stripHelpMarkup('threshold a < 5 > 0 holds'), 'threshold a < 5 > 0 holds', reason: 'math not eaten');
    expect(
      stripHelpMarkup('<register>'),
      '<register>',
      reason: 'a bare angle-bracket token is real data, not markup -> must not collapse to empty',
    );
    expect(stripHelpMarkup('<default>'), '<default>');
    expect(
      stripHelpMarkup('See <B>error in</B>  for details'),
      'See error in for details',
      reason: 'removing an inline tag must not leave a double space',
    );
  });

  test('buildDiagram terminates on a parentOid cycle (reanchorViewport guard)', () {
    final records = <int>[
      ...open(0x7e, 100),
      ...bounds(0, 0, 400, 400),
      ...open(0xaa, 1, tag: 0x1a),
      ...open(0xaa, 2, tag: 0x1b),
      ...open(0xaa, 1, tag: 0x1c),
      ...open(0x50, 5, tag: 0x1d),
      ...bounds(10, 10, 30, 30),
      ...close(0x1d),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final sw = Stopwatch()..start();
    expect(() => buildDiagram(body), returnsNormally);
    expect(
      sw.elapsedMilliseconds,
      lessThan(2000),
      reason: 'duplicate oids cross-link the parent chain (1->2->1); reanchorViewport must not loop',
    );
  });

  test('buildDiagram is total over arbitrary bytes', () {
    final junk = Uint8List.fromList([for (var i = 0; i < 400; i++) (i * 17 + 3) & 0xff]);
    expect(() {
      final d = buildDiagram(junk);
      for (final o in d.objects) {
        o.absBounds;
        o.category;
        o.typeKind;
      }
    }, returnsNormally);
  });

  test('buildDiagram terminates on a duplicate-oid control under a viewport (no infinite loop)', () {
    final records = <int>[
      ...open(0x7e, 100),
      ...bounds(0, 0, 500, 500),
      ...open(0x11c, 1, tag: 0x1a),
      ...bounds(10, 10, 200, 200),
      ...open(0x50, 7, tag: 0x1b),
      ...bounds(-300, 5, -283, 90),
      ...open(0x50, 7, tag: 0x1c),
      ...bounds(0, 5, 17, 90),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final sw = Stopwatch()..start();
    expect(() => buildDiagram(body), returnsNormally);
    expect(
      sw.elapsedMilliseconds,
      lessThan(2000),
      reason: 'a dup-oid control under a 0x11c viewport makes kids[oid] contain itself; shiftSubtree must not loop',
    );
  });
}
