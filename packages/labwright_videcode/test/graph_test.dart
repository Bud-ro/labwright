import 'dart:typed_data';

import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:test/test.dart';

// Object/group open: 10 <tag> 02 fe <u16 kind> fd <u16 oid>
List<int> open(int kind, int oid, {int tag = 0x19}) =>
    [0x10, tag, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
List<int> close([int tag = 0x19]) => [0x08, tag]; // popped positionally
List<int> bounds(int t, int l, int b, int r) =>
    [0xc4, 0x2d, 0x08, t >> 8, t & 0xff, l >> 8, l & 0xff, b >> 8, b & 0xff, r >> 8, r & 0xff];
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];
List<int> fmt74(String s) => [0xc4, 0x74, s.length, ...s.codeUnits];
List<int> enum2e(List<String> items) {
  final b = <int>[for (final it in items) ...[it.length, ...it.codeUnits]];
  return [0xc4, 0x2e, b.length, ...b];
}

void main() {
  test('bracket tree: parent/child nesting + absolute coordinates', () {
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 500, 500), // root diagram at origin
      ...open(0x50, 2, tag: 0x1a), ...bounds(10, 20, 30, 40), ...caption('Trigger'), // child terminal, local
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
    // local bounds (10,20,30,40); abs = parent origin (0,0) + local -> same here
    expect([child.absBounds!.top, child.absBounds!.left, child.absBounds!.bottom, child.absBounds!.right],
        [10, 20, 30, 40]);
    expect(d.children(1).map((o) => o.oid), [2]);
  });

  test('absolute coordinates compose down the object-ancestor chain', () {
    final records = <int>[
      ...open(0x7e, 1), ...bounds(100, 200, 900, 900), // ancestor origin (100,200)
      ...open(0x53, 2, tag: 0x1a), ...bounds(5, 5, 50, 50), // mid origin +(5,5) -> (105,205)
      ...open(0x50, 3, tag: 0x1b), ...bounds(1, 2, 11, 12), // leaf local (1,2) -> abs (106,207)
      ...close(0x1b), ...close(0x1a), ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final leaf = buildDiagram(body).byId[3]!;
    expect([leaf.absBounds!.top, leaf.absBounds!.left], [106, 207]); // 100+5+1, 200+5+2
  });

  test('structure child-membership refs attach to the structure, not terminals', () {
    final records = <int>[
      ...open(0x53, 1), ...bounds(0, 0, 100, 100), // a structure
      0x10, 0x55, 0x01, 0xfb, 0x00, 0x02, // child reflist group of 2
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x09, // -> oid 9
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x0a, // -> oid 10
      ...close(0x55),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final s = buildDiagram(body).byId[1]!;
    expect(s.category, ViObjectKind.structure);
    expect(s.refs, [9, 10]);
  });

  test('the full 0x14 typed-ref family is collected (childRef + memberRef) into the object graph', () {
    final records = <int>[
      ...open(0x53, 1), ...bounds(0, 0, 100, 100),
      0x14, 0x19, 0x01, 0xfd, 0x00, 0x09, // childRef -> 9
      0x14, 0x4f, 0x01, 0xfd, 0x00, 0x0b, // memberRef -> 11
      0x14, 0x50, 0x01, 0xfd, 0x00, 0x0c, // siblingRef -> 12
      0x14, 0x53, 0x01, 0xfd, 0x00, 0x07, // 0x53 LITERAL — not a ref, must be ignored
      ...close(),
    ];
    final s = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records])).byId[1]!;
    expect(s.refs, [9]); // childRef subset (backward-compatible)
    expect(s.typedRefs[HeapRefKind.childRef], [9]);
    expect(s.typedRefs[HeapRefKind.memberRef], [11]);
    expect(s.typedRefs[HeapRefKind.siblingRef], [12]);
    expect(s.typedRefs.containsKey(HeapRefKind.literal), isFalse); // 0x53 literal not collected
    // memberOids = childRef ∪ memberRef (used by the diagram to highlight members).
    expect(s.memberOids.toSet(), {9, 11});
  });

  test('classifies kinds and infers type from attached C4 records', () {
    final records = <int>[
      ...open(0x68, 1), ...bounds(0, 0, 17, 17), ...close(), // terminal
      ...open(0x12, 2), ...bounds(0, 0, 40, 40), ...close(), // node
      ...open(0x50, 3), ...bounds(0, 0, 17, 80), ...fmt74('%#_6g'), ...close(), // numeric float
      ...open(0x50, 4), ...bounds(0, 0, 17, 80), ...fmt74('%04d'), ...close(), // numeric int
      ...open(0x0d, 5), ...bounds(0, 0, 17, 80), ...enum2e(['Low', 'High']), ...close(), // enum
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[1]!.category, ViObjectKind.terminal);
    expect(d.byId[2]!.category, ViObjectKind.node);
    expect(d.byId[3]!.typeKind, ViTypeKind.numericFloat);
    expect(d.byId[4]!.typeKind, ViTypeKind.numericInt);
    expect(d.byId[5]!.typeKind, ViTypeKind.enumRing);
  });

  test('scrolled-cluster control terminals are re-anchored to their viewport', () {
    // A cluster (0x53) at (200,50) holds a content viewport (0x11c) at local
    // (10,5) -> abs (210,55). Its control terminals (0x50) live in the viewport's
    // scrolled content frame with large-negative tops, so naive ancestor
    // composition floats them ~300px above the cluster. After re-anchoring they
    // should form a clean column inside the viewport.
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 500, 500),
      ...open(0x53, 2), ...bounds(200, 50, 400, 200),
      ...open(0x11c, 3), ...bounds(10, 5, 160, 130), // viewport abs (210,55)
      ...open(0x50, 4), ...bounds(-300, 9, -256, 105), // group min top
      ...open(0xa, 6), ...bounds(0, 11, 17, 107), ...caption('Start'), // label rides along
      ...close(),
      ...open(0x4f, 8), ...bounds(5, 10, 17, 30), // control nested in a control: rides along, NOT re-anchored
      ...close(),
      ...close(),
      ...open(0x50, 5), ...bounds(-262, 9, -218, 105), // +38 below #4
      ...close(),
      ...close(), // close viewport
      ...close(), // close cluster
      ...open(0x50, 7), ...bounds(300, 300, 320, 350), // direct terminal, NOT under a viewport
      ...close(),
      ...close(), // close root
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    final vp = d.byId[3]!.absBounds!;
    final c4 = d.byId[4]!.absBounds!, c5 = d.byId[5]!.absBounds!;

    // #4 re-anchored to the viewport origin; #5 sits 38px below it; both inside.
    expect([c4.top, c4.left], [210, 55]);
    expect(c5.top, 248);
    for (final c in [c4, c5]) {
      final cy = (c.top + c.bottom) ~/ 2;
      expect(cy >= vp.top && cy <= vp.bottom, isTrue, reason: 'control center inside viewport');
    }
    // The control's label subtree moved with it (no longer detached).
    expect(d.byId[6]!.absBounds!.top, 210);
    // A control nested INSIDE another control rides along with its parent's
    // shift (relative to #4), rather than being re-anchored to the viewport.
    expect([d.byId[8]!.absBounds!.top, d.byId[8]!.absBounds!.left], [215, 65]);
    // A direct on-diagram terminal (not under a 0x11c) is left untouched.
    expect([d.byId[7]!.absBounds!.top, d.byId[7]!.absBounds!.left], [300, 300]);
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
    // named classes resolve through ViHeapObject + drive classifyObject's category.
    expect(HeapObjectClass.fromCode(0x50).label, 'Numeric control');
    expect(classifyObject(kind: 0x68, termCount: 0), ViObjectKind.terminal);
    expect(classifyObject(kind: 0x12, termCount: 0), ViObjectKind.node);
    expect(classifyObject(kind: 0x53, termCount: 0), ViObjectKind.structure);
    // Newly catalogued block-diagram nodes (32×32 icon footprint under 0x1b).
    expect(classifyObject(kind: 0x2f, termCount: 0), ViObjectKind.node);
    expect(classifyObject(kind: 0x31, termCount: 0), ViObjectKind.node);
    expect(classifyObject(kind: 0x16, termCount: 0), ViObjectKind.terminal); // free-standing BD leaf
    expect(classifyObject(kind: 0x2c, termCount: 0), ViObjectKind.structure); // BD structure frame
    expect(classifyObject(kind: 0x95, termCount: 0), ViObjectKind.terminal); // case selector label
    expect(classifyObject(kind: 0x177, termCount: 0), ViObjectKind.decoration); // node glyph
    expect(classifyObject(kind: 0x63, termCount: 0), ViObjectKind.node); // growable node
    for (final k in [0x8c, 0x3a, 0xd6, 0x32, 0xc5, 0x104, 0x44, 0x3e, 0x34, 0xa9, 0x93, 0x172, 0x6c, 0x36, 0x153,
      0x6a, 0xbd, 0x114, 0xb6, 0xb9, 0x48, 0xeb, 0x103, 0x14a]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.node); // BD nodes (caption- or icon-confirmed)
    }
    for (final k in [0x55, 0x4e, 0x10c, 0xc2]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.terminal); // control terminal / constant
    }
    for (final k in [0xca, 0x29, 0xd5, 0x121]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.structure); // sequence/event/frame structures
    }
    for (final k in [0x20, 0x21, 0xcd, 0x14d]) {
      expect(classifyObject(kind: k, termCount: 0), ViObjectKind.structure); // loop/case/disable/in-place frames
    }
    // the C4-1F terminal signal still wins over the catalog category.
    expect(classifyObject(kind: 0x50, termCount: 2), ViObjectKind.terminalCluster);
  });

  test('section-dependent class labels stay honest about what was observed', () {
    // Guards the section-label honesty work against silent reverts.
    // 0x53 is the ONLY genuinely dual-role class (5745 BD loops that own a 0x11c
    // viewport + 21993 FP containers), so its label MUST name both roles and must
    // not revert to a section-blind "Loop (while/for)" that mislabels ~22k FP objs.
    final loop = HeapObjectClass.fromCode(0x53).label;
    expect(loop, contains('(BD)'));
    expect(loop, contains('(FP)'));
    expect(loop, isNot('Loop (while/for)'));
    // 0x12 and 0x4c appear 0 times in the decoded BD object trees, so their legacy
    // BD names ("function node" / "diagram frame") are misattributions — the labels
    // must name the observed FP role only and must NOT re-assert a (BD) role.
    for (final code in [0x12, 0x4c]) {
      final label = HeapObjectClass.fromCode(code).label;
      expect(label, contains('(FP)'), reason: '0x${code.toRadixString(16)} lost its FP-role tag');
      expect(label, isNot(contains('(BD)')), reason: '0x${code.toRadixString(16)} re-asserts an unobserved BD role');
    }
    // 0x52 owns no 0x11c viewport on either side (same flat-container profile as
    // 0x64) -> section-CONSISTENT, not a split, and must not re-assert case/sequence.
    final c52 = HeapObjectClass.fromCode(0x52).label;
    expect(c52, isNot(contains('case')));
    expect(c52, isNot(contains('Case')));
  });

  test('enum/ring items are parsed and propagated up to the enclosing control', () {
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x57, 2, tag: 0x1a), ...bounds(10, 10, 30, 110), // enum control
      ...open(0x0d, 3, tag: 0x1b), ...bounds(12, 12, 28, 100), ...enum2e(['Low', 'Med', 'High']), // item list
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    // items decoded on the 0x0d item-list object...
    expect(d.byId[3]!.items, ['Low', 'Med', 'High']);
    // ...and propagated up to its enclosing 0x57 control (used by faithful mode).
    expect(d.byId[2]!.items, ['Low', 'Med', 'High']);
  });

  test('enum item parsing rejects the WHOLE table on overrun or non-printable bytes', () {
    // Raw C4 2E with a deliberately corrupt pascal-string payload.
    List<int> rawEnum(List<int> payload) => [0xc4, 0x2e, payload.length, ...payload];
    List<int> build(List<int> enumRec) {
      final records = <int>[
        ...open(0x7e, 1), ...bounds(0, 0, 100, 100),
        ...open(0x0d, 2, tag: 0x1b), ...bounds(0, 0, 17, 80), ...enumRec,
        ...close(0x1b),
        ...close(),
      ];
      return [0, 0, 0, records.length, ...records];
    }

    // First item claims length 10 but only 3 bytes follow -> overrun -> reject all.
    final overrun = buildDiagram(Uint8List.fromList(build(rawEnum([0x0a, 0x41, 0x42, 0x43]))));
    expect(overrun.byId[2]!.items, isEmpty);
    // An embedded non-printable byte (0x00) in an item -> reject the whole table.
    final nonPrintable = buildDiagram(Uint8List.fromList(build(rawEnum([0x03, 0x41, 0x00, 0x43]))));
    expect(nonPrintable.byId[2]!.items, isEmpty);
  });

  test('control range (0x20/0x21) + help (0x6C FF) collected ONLY on controls, not decorations', () {
    List<int> f64rec(int id, double v) {
      final d = ByteData(8)..setFloat64(0, v);
      return [0xc5, id, 0x08, ...d.buffer.asUint8List()];
    }
    List<int> c6blob(int id, String s) {
      final len = 4 + s.length;
      return [0xc6, id, 0xff, len >> 8, len & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    }

    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a), ...bounds(0, 0, 17, 80), // a numeric control
      ...f64rec(0x20, -5.0), ...f64rec(0x21, 10.0), // range via the 0x20/0x21 f64 form
      ...c6blob(0x6c, 'a tooltip'), // help text (FF blob)
      ...close(0x1a),
      ...open(0x8f, 3, tag: 0x1b), ...bounds(0, 0, 10, 10), // a decoration
      ...f64rec(0x20, 1.0), ...f64rec(0x21, -1.0), // inverted; must NOT attach to a non-control
      ...close(0x1b),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    final ctl = d.byId[2]!, deco = d.byId[3]!;
    expect(ctl.controlMin, -5.0);
    expect(ctl.controlMax, 10.0);
    expect(ctl.helpText, 'a tooltip');
    expect(deco.controlMin, isNull); // 0x8f decoration: range not attached
    expect(deco.controlMax, isNull);
  });

  test('help text propagates up from a non-drawable child to its nearest drawable control', () {
    List<int> c6blob(int id, String s) {
      final len = 4 + s.length;
      return [0xc6, id, 0xff, len >> 8, len & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    }
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a), ...bounds(10, 10, 30, 100), // a drawable control
      ...open(0xc1, 3, tag: 0x1b), // a tip-strip child, NO bounds (not drawable)
      ...c6blob(0x6c, 'hover help'),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.absBounds, isNull); // the tip-strip carries the help but isn't drawn
    expect(d.byId[2]!.helpText, 'hover help'); // ...propagated up to the drawn control
  });

  test('help propagation skips a non-drawable intermediate to reach the nearest drawable', () {
    List<int> c6blob(int id, String s) =>
        [0xc6, id, 0xff, (4 + s.length) >> 8, (4 + s.length) & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a), ...bounds(10, 10, 30, 100), // drawable control
      ...open(0x0c, 3, tag: 0x1b), // a non-drawable intermediate (terminal cluster, NO bounds)
      ...open(0xc1, 4, tag: 0x1c), // tip-strip under the intermediate, carries the help
      ...c6blob(0x6c, 'deep help'),
      ...close(0x1c), ...close(0x1b), ...close(0x1a), ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.absBounds, isNull); // the intermediate is genuinely not drawn (gets skipped)
    expect(d.byId[3]!.helpText, isNull); // ...and is NOT where the help lands
    expect(d.byId[2]!.helpText, 'deep help'); // help reaches the nearest DRAWABLE ancestor
  });

  test('help propagation lands on a 0x53 structure when that is the nearest drawable ancestor', () {
    List<int> c6blob(int id, String s) =>
        [0xc6, id, 0xff, (4 + s.length) >> 8, (4 + s.length) & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x53, 1), ...bounds(0, 0, 200, 200), // a drawable structure (intentional target)
      ...open(0xc1, 2, tag: 0x1a), // tip-strip child, no bounds
      ...c6blob(0x6c, 'structure help'),
      ...close(0x1a), ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[1]!.helpText, 'structure help'); // structures legitimately own help too
  });

  test('help propagation never overwrites an ancestor that already carries its own help (??=)', () {
    List<int> c6blob(int id, String s) =>
        [0xc6, id, 0xff, (4 + s.length) >> 8, (4 + s.length) & 0xff, 0, 0, 0, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x50, 1), ...bounds(10, 10, 30, 100), // drawable control with its OWN help
      ...c6blob(0x6c, 'own help'),
      ...open(0xc1, 2, tag: 0x1a), // a child tip-strip with DIFFERENT help
      ...c6blob(0x6c, 'child help'),
      ...close(0x1a), ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[1]!.helpText, 'own help'); // first-wins: the control's own help is preserved
  });

  test('a BD node inherits its name from its child 0xa caption (for details/tooltip)', () {
    final records = <int>[
      ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
      ...open(0x2f, 2, tag: 0x1a), ...bounds(10, 10, 42, 42), // a node (0x2f), no own caption
      ...open(0xa, 3, tag: 0x1b), // its label child
      ...caption('Build Array'), // C4 22 -> the 0xa child's label
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final d = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records]));
    expect(d.byId[3]!.label, 'Build Array'); // the child 0xa carries the caption
    expect(d.byId[2]!.label, 'Build Array'); // ...propagated up to the node so it can be named
  });

  test('a 0x6C <u8len> library token does NOT become helpText (only the FF blob does)', () {
    // C6 6C <u8 len> <u32 strlen><ascii> — a library/format token, NOT help text.
    List<int> u8tok(String s) => [0xc6, 0x6c, 4 + s.length, 0, 0, 0, s.length, ...s.codeUnits];
    final records = <int>[
      ...open(0x50, 1), ...bounds(0, 0, 17, 80),
      ...u8tok('ps2000aRunStreaming'), // decodes to a string, but is NOT help
      ...close(),
    ];
    final o = buildDiagram(Uint8List.fromList([0, 0, 0, records.length, ...records])).byId[1]!;
    expect(o.helpText, isNull); // the <u8len> token must not be surfaced as help
  });

  test('formatControlRange renders honestly (finite-only, inverted/±∞/NaN suppressed)', () {
    expect(formatControlRange(-5.0, 10.0), '-5 … 10');
    expect(formatControlRange(0.0, 2.5), '0 … 2.5');
    expect(formatControlRange(5.0, double.infinity), '≥ 5'); // +∞ max -> one-sided
    expect(formatControlRange(double.negativeInfinity, 10.0), '≤ 10');
    expect(formatControlRange(double.negativeInfinity, double.infinity), isNull); // both ±∞ -> nothing
    expect(formatControlRange(null, null), isNull);
    expect(formatControlRange(1.0, -1.0), isNull); // inverted finite pair -> nothing
    expect(formatControlRange(5.0, 5.0), isNull); // degenerate equal pair -> noise, not a range
    expect(formatControlRange(0.0, -0.0), isNull); // 0 vs -0.0 (lo >= hi) -> nothing
    expect(formatControlRange(0.0, double.nan), isNull); // NaN max -> untrustworthy pair
    expect(formatControlRange(double.nan, 10.0), isNull);
  });

  test('stripHelpMarkup removes LabVIEW markup tags for display but keeps real text', () {
    expect(stripHelpMarkup('<B>error out</B> contains error information.'),
        'error out contains error information.');
    expect(stripHelpMarkup('<B>code</B> is 0.'), 'code is 0.');
    expect(stripHelpMarkup('line one\n<I>line</I> two'), 'line one\nline two'); // newlines kept
    expect(stripHelpMarkup('plain help, no tags'), 'plain help, no tags');
    expect(stripHelpMarkup('threshold a < 5 > 0 holds'), 'threshold a < 5 > 0 holds'); // math not eaten
    // A help string that IS a bare angle-bracket token is real data, not markup:
    // stripping must NOT collapse it to empty (else the UI shows nothing).
    expect(stripHelpMarkup('<register>'), '<register>');
    expect(stripHelpMarkup('<default>'), '<default>');
    // Removing an inline tag must not leave a double space (corpus boilerplate).
    expect(stripHelpMarkup('See <B>error in</B>  for details'), 'See error in for details');
  });

  test('buildDiagram terminates on a parentOid cycle (reanchorViewport guard)', () {
    // Duplicate oids cross-link the parent chain (byOid last-wins): a control's
    // ancestor walk 1->2->1 would loop forever in reanchorViewport without a guard.
    final records = <int>[
      ...open(0x7e, 100), ...bounds(0, 0, 400, 400),
      ...open(0xaa, 1, tag: 0x1a), // non-control, no bounds
      ...open(0xaa, 2, tag: 0x1b),
      ...open(0xaa, 1, tag: 0x1c), // dup oid 1 -> byOid[1]=this (parentOid 2)
      ...open(0x50, 5, tag: 0x1d), ...bounds(10, 10, 30, 30), // control, parentOid 1
      ...close(0x1d),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final sw = Stopwatch()..start();
    expect(() => buildDiagram(body), returnsNormally);
    expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'must not hang on a parentOid cycle');
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
    // A control terminal (0x50) nested directly under another object sharing its
    // oid, inside a 0x11c viewport — makes the re-anchor `kids[oid]` list contain
    // itself. Before the visited-guard this looped forever in shiftSubtree.
    final records = <int>[
      ...open(0x7e, 100), ...bounds(0, 0, 500, 500),
      ...open(0x11c, 1, tag: 0x1a), ...bounds(10, 10, 200, 200), // viewport
      ...open(0x50, 7, tag: 0x1b), ...bounds(-300, 5, -283, 90), // control, large-negative top
      ...open(0x50, 7, tag: 0x1c), ...bounds(0, 5, 17, 90), // SAME oid 7, nested
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ];
    final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
    final sw = Stopwatch()..start();
    expect(() => buildDiagram(body), returnsNormally);
    expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'should not hang');
  });
}
