import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

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
List<int> enum2e(List<String> items) {
  final b = [for (final it in items) ...pascal(it)];
  return [0xc4, 0x2e, b.length, ...b];
}

/// `C6 <id> FF <u16 len> <u32 strlen> <text>` string blob.
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

/// Description/help record `C4 19 <len> <text>` ([HeapRecord.descriptionText]).
List<int> help(String s) => [0xc4, 0x19, s.length, ...s.codeUnits];

/// Two-byte-BE numeric attribute record `44 <id> <u16 value>`.
List<int> attrU16(int id, int v) => [0x44, id, v >> 8, v & 0xff];

/// Length-prefixed container attribute record `C5 <id> <u8 len> <payload>`.
List<int> c5(int id, List<int> payload) => [0xc5, id, payload.length, ...payload];

/// Three-byte-BE numeric attribute record `64 <id> <u24 value>`.
List<int> attrU24(int id, int v) => [0x64, id, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// One-byte numeric attribute record `24 <id> <u8 value>`.
List<int> attrU8(int id, int v) => [0x24, id, v & 0xff];

/// Four-byte-BE numeric attribute record `84 <id> <u32 value>`.
List<int> attrU32(int id, int v) => [0x84, id, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

ViDiagram dia(List<int> records) => buildDiagram(u8([0, 0, 0, records.length, ...records]));

void main() {
  group('resolveDataSpaceTypes', resolveTypesTests);
  test('primResId: captured off the 0xEA attribute and named through PrimOp', () {
    final d = dia([
      ...open(0x2f, 1),
      ...bounds(10, 10, 36, 42),
      ...attrU16(0xea, 1051),
      ...close(),
      ...open(0x2f, 2),
      ...attrU16(0xea, 9999),
      ...close(),
    ]);
    expect((d.byId[1]!.primResId, d.byId[1]!.primName), (1051, 'Subtract'));
    expect((d.byId[2]!.primResId, d.byId[2]!.primName), (9999, null), reason: 'uncatalogued ids stay unnamed');
  });

  test('primResId capture is gated to class 0x2F and the u16 width', () {
    final d = dia([
      ...open(0x50, 1),
      ...attrU16(0xea, 1051),
      ...close(),
      ...open(0x2f, 2),
      0xe4, 0xea, // flag-width 0xEA form: must not lock in primResId=1
      ...attrU16(0xea, 1051),
      ...close(),
    ]);
    expect(d.byId[1]!.primResId, isNull, reason: 'off-class carriers are not primitive identities');
    expect(d.byId[2]!.primResId, 1051, reason: 'the u16 record wins; the flag form is inert');
  });

  test('decodeWireRoute: both headers, FF length escape, junction codes reject', () {
    // basic.png's x-input wire: 4 points, jogs down then right, H 28 / V 12.
    final r1 = decodeWireRoute(u8([0x04, 0x08, 0x00, 0x00, 28, 12]))!;
    expect(r1.pointCount, 4);
    expect(r1.segmentLengths, [28, 12]);
    expect(r1.jointSigns, [1, 1]);
    // basic.png's y-input wire: same lengths, first joint jogs up.
    expect(decodeWireRoute(u8([0x04, 0x08, 0x01, 0x00, 28, 12]))!.jointSigns, [-1, 1]);
    // FF escape: a 256-unit segment.
    final r2 = decodeWireRoute(u8([0x03, 0x08, 0x01, 0xff, 0x01, 0x00]))!;
    expect(r2.segmentLengths, [256]);
    expect(r2.jointSigns, [-1]);
    // Extended header stores pointCount-1 lengths.
    final r3 = decodeWireRoute(u8([0x05, 0x00, 0x08, 0x00, 0x01, 0x00, 5, 6, 7, 8]))!;
    expect((r3.pointCount, r3.segmentLengths.length), (5, 4));
    // Branching junction codes are not decoded: null, never a guess.
    expect(decodeWireRoute(u8([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 13, 66, 11, 247])), isNull);
    expect(decodeWireRoute(u8([0x04])), isNull);
  });

  test('a signal object captures its container wire table onto the wire model', () {
    final d = dia([
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0002'),
      ...hx('14 19 01 fd 0003'),
      ...c5(0xe7, [0x04, 0x08, 0x00, 0x00, 28, 12]),
      ...close(),
    ]);
    final route = d.wires.single.route!;
    expect(route.pointCount, 4);
    expect(route.segmentLengths, [28, 12]);
    expect(route.jointSigns, [1, 1]);
  });

  test('endpointTerminalBounds: attach rect = termBounds + enclosing frame origin', () {
    final d = dia([
      ...open(0x20, 1), // loop structure at (100, 50)
      ...bounds(100, 50, 200, 150),
      ...open(0x22, 2, tag: 0x1a), // tunnel terminal: childRefs the endpoint, carries termBounds
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 0, 0, 19, 0, 9]), // t:10 l:0 b:19 r:9 — on the left border
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a), // the wire-endpoint DCO (bounds-less)
      ...close(0x1a),
      ...open(0x16, 4, tag: 0x1a), // an endpoint no terminal names
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9), // the signal binding both endpoints
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0004'),
      ...close(),
    ]);
    expect(d.endpointTerminal(3)!.oid, 2);
    final pos = d.endpointTerminalBounds(3)!;
    expect((pos.top, pos.left, pos.bottom, pos.right), (110, 50, 119, 59));
    final wire = d.wires.single;
    expect(wire.endpointTerminalBounds.first!.top, 110);
    expect(wire.endpointTerminalBounds.last, isNull, reason: 'no terminal names endpoint 4');
    expect(d.endpointTerminalBounds(2), isNull, reason: 'gated to the endpoint DCO kinds');
    expect(d.endpointTerminal(1), isNull);
  });

  test('isLabelHidden: objFlags bit 0x08 on label parts only', () {
    final d = dia([
      ...open(0xa, 1),
      ...caption('hidden'),
      ...attrU24(0xcb, 0x17114a), // objFlags with the hidden bit 0x08 set
      ...close(),
      ...open(0xa, 2),
      ...caption('shown'),
      ...attrU24(0xcb, 0x171142),
      ...close(),
      ...open(0x95, 3),
      ...attrU24(0xcb, 0x17114a),
      ...close(),
    ]);
    expect(d.byId[1]!.isLabelHidden, isTrue);
    expect(d.byId[2]!.isLabelHidden, isFalse);
    expect(
      d.byId[3]!.isLabelHidden,
      isFalse,
      reason: 'the getter is scoped to label parts; the bit is undecoded elsewhere',
    );
  });

  test('visibleFrameIndex: dIdx on multi-frame structure kinds, bit-31 masked', () {
    final d = dia([
      ...open(0x2c, 1),
      ...attrU8(0x4d, 1),
      ...close(),
      ...open(0x2c, 2),
      ...attrU32(0x4d, 0x80000002), // the bit-31 flag form
      ...close(),
      ...open(0x2c, 3),
      ...close(),
      ...open(0x50, 4),
      ...attrU8(0x4d, 1),
      ...close(),
    ]);
    expect(d.byId[1]!.visibleFrameIndex, 1);
    expect(d.byId[2]!.visibleFrameIndex, 2, reason: 'bit 31 is a flag, not index');
    expect(d.byId[3]!.visibleFrameIndex, 0, reason: 'absent record displays the first frame');
    expect(d.byId[4]!.dIdx, isNull, reason: 'capture is gated to the multi-frame structure kinds');
  });

  test('PrimOp catalog: unique ids, lookup round-trip', () {
    final ids = PrimOp.values.map((op) => op.id).toSet();
    expect(ids.length, PrimOp.values.length, reason: 'catalog ids are unique');
    for (final op in PrimOp.values) {
      expect(PrimOp.fromId(op.id), op);
      expect(op.opName, isNotEmpty);
    }
    expect(PrimOp.fromId(9999), isNull);
  });

  test('bracket tree: parent/child nesting, roots, children(), absolute coordinates', () {
    final d = dia([
      ...open(0x7e, 1),
      ...bounds(0, 0, 500, 500),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(10, 20, 30, 40),
      ...caption('Trigger'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(d.objects.length, 2);
    expect(d.roots.map((o) => o.oid), [1]);
    final child = d.byId[2]!;
    expect((child.parentOid, child.label), (1, 'Trigger'));
    final r = child.absBounds!;
    expect([r.top, r.left, r.bottom, r.right], [10, 20, 30, 40], reason: 'abs = parent origin (0,0) + local');
    expect(d.children(1).map((o) => o.oid), [2]);
  });

  test('absolute coordinates compose down the object-ancestor chain', () {
    final leaf = dia([
      ...open(0x7e, 1),
      ...bounds(100, 200, 900, 900),
      ...open(0x53, 2, tag: 0x1a),
      ...bounds(5, 5, 50, 50),
      ...open(0x50, 3, tag: 0x1b),
      ...bounds(1, 2, 11, 12),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ]).byId[3]!;
    expect([leaf.absBounds!.top, leaf.absBounds!.left], [106, 207], reason: 'top 100+5+1, left 200+5+2');
  });

  test('typed-ref family collected; membership refs attach to the structure, not terminals', () {
    final s = dia([
      ...open(0x53, 1),
      ...bounds(0, 0, 100, 100),
      ...hx('10 55 01 fb 0002'),
      ...hx('14 19 01 fd 0009'),
      ...hx('14 4f 01 fd 000b'),
      ...hx('14 50 01 fd 000c'),
      ...hx('14 53 01 fd 0007'),
      ...close(0x55),
      ...close(),
    ]).byId[1]!;
    expect(s.category, ViObjectKind.structure);
    expect(s.refs, [9], reason: 's.refs is the backward-compatible childRef subset');
    expect(s.typedRefs[HeapRefKind.childRef], [9]);
    expect(s.typedRefs[HeapRefKind.dcoRef], [11]);
    expect(s.typedRefs[HeapRefKind.dcoAggRef], [12]);
    expect(s.typedRefs[HeapRefKind.ddoRef], [7], reason: '14 53 is a cross-heap display-object reference');
    expect(s.memberOids.toSet(), {9, 11}, reason: 'memberOids = childRef ∪ dcoRef');

    final multi = dia([
      ...open(0x53, 1),
      ...bounds(0, 0, 100, 100),
      ...hx('10 55 01 fb 0002'),
      ...hx('14 19 01 fd 0009'),
      ...hx('14 19 01 fd 000a'),
      ...close(0x55),
      ...close(),
    ]).byId[1]!;
    expect(multi.refs, [9, 10], reason: 'child-membership refs inside the 0x55 group attach to the structure');
  });

  test('classifies kinds and infers type from attached C4 records', () {
    List<int> fmt74(String s) => [0xc4, 0x74, s.length, ...s.codeUnits];
    final d = dia([
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
    ]);
    expect(d.byId[1]!.category, ViObjectKind.terminal);
    expect(d.byId[2]!.category, ViObjectKind.node);
    expect(d.byId[3]!.typeKind, ViTypeKind.numericFloat);
    expect(d.byId[4]!.typeKind, ViTypeKind.numericInt);
    expect(d.byId[5]!.typeKind, ViTypeKind.enumRing);
  });

  test('scrolled-cluster control terminals are re-anchored to their viewport', () {
    final d = dia([
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
    ]);
    final vp = d.byId[3]!.absBounds!;
    final c4 = d.byId[4]!.absBounds!, c5 = d.byId[5]!.absBounds!;
    expect([c4.top, c4.left], [210, 55], reason: '#4 re-anchored to the viewport origin');
    expect(c5.top, 248, reason: '#5 sits 38px below #4 (-262 vs -300) -> 210+38');
    for (final c in [c4, c5]) {
      final cy = (c.top + c.bottom) ~/ 2;
      expect(cy >= vp.top && cy <= vp.bottom, isTrue, reason: 'control center inside viewport');
    }
    expect(d.byId[6]!.absBounds!.top, 210, reason: "#4's label subtree rides along");
    expect([d.byId[8]!.absBounds!.top, d.byId[8]!.absBounds!.left], [215, 65], reason: 'nested control rides parent');
    expect([d.byId[7]!.absBounds!.top, d.byId[7]!.absBounds!.left], [300, 300], reason: 'not under 0x11c: untouched');
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

    const byCategory = <ViObjectKind, List<int>>{
      // BD nodes (caption- or icon-confirmed) + growable/icon-footprint nodes
      ViObjectKind.node: [
        0x12, 0x2f, 0x31, 0x63, 0x8c, 0x3a, 0xd6, 0x32, 0xc5, 0x104, 0x44, 0x3e, 0x34, 0xa9, 0x93, 0x172, //
        0x6c, 0x36, 0x153, 0x6a, 0xbd, 0x114, 0xb6, 0xb9, 0x48, 0xeb, 0x103, 0x14a,
      ],
      // free-standing leaves, case selector label, control terminals / constants
      ViObjectKind.terminal: [0x68, 0x16, 0x95, 0x55, 0x4e, 0x10c, 0xc2],
      // sequence/event/frame + loop/case/disable/in-place structures
      ViObjectKind.structure: [0x53, 0x2c, 0xca, 0x29, 0xd5, 0x121, 0x20, 0x21, 0xcd, 0x14d],
      ViObjectKind.decoration: [0x177],
    };
    byCategory.forEach((category, kinds) {
      for (final k in kinds) {
        expect(classifyObject(kind: k, termCount: 0), category, reason: '0x${k.toRadixString(16)}');
      }
    });
    expect(
      classifyObject(kind: 0x50, termCount: 2),
      ViObjectKind.terminalCluster,
      reason: 'the C4-1F terminal signal wins over the catalog category',
    );
  });

  test('section-dependent class labels stay honest about what was observed', () {
    final loop = HeapObjectClass.fromCode(0x53).label;
    expect(loop, contains('(BD)'), reason: '0x53 is genuinely dual-role: BD loops + FP containers');
    expect(loop, contains('(FP)'));
    expect(loop, isNot('Loop (while/for)'), reason: 'a section-blind label would mislabel FP containers');
    for (final code in [0x12, 0x4c]) {
      final label = HeapObjectClass.fromCode(code).label;
      expect(label, contains('(FP)'), reason: '0x${code.toRadixString(16)} lost its FP-role tag');
      expect(label, isNot(contains('(BD)')), reason: '0x${code.toRadixString(16)} re-asserts an unobserved BD role');
    }
    final c52 = HeapObjectClass.fromCode(0x52).label;
    expect(c52, isNot(contains('case')));
    expect(c52, isNot(contains('Case')));
  });

  test('enum/ring items parse and propagate up to the enclosing control', () {
    final d = dia([
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
    ]);
    expect(d.byId[3]!.items, ['Low', 'Med', 'High']);
    expect(d.byId[2]!.items, ['Low', 'Med', 'High'], reason: 'items propagate up to the enclosing 0x57 control');
  });

  test('graph plot names (C4 27) attach to the 0x5E graph object, in heap order', () {
    List<int> plot(String s) => [0xc4, 0x27, s.length, ...s.codeUnits];
    final d = dia([
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x5e, 2, tag: 0x1a),
      ...bounds(10, 10, 200, 300),
      ...plot('Plot 0'),
      ...plot('Plot 1'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(d.byId[2]!.plotNames, ['Plot 0', 'Plot 1']);
    expect(d.byId[1]!.plotNames, isEmpty, reason: 'plot names attach to the graph, not the root');
  });

  test('enum item parsing rejects the WHOLE table on overrun or non-printable bytes', () {
    ViDiagram build(List<int> payload) => dia([
      ...open(0x7e, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x0d, 2, tag: 0x1b),
      ...bounds(0, 0, 17, 80),
      0xc4,
      0x2e,
      payload.length,
      ...payload,
      ...close(0x1b),
      ...close(),
    ]);
    expect(build([0x0a, 0x41, 0x42, 0x43]).byId[2]!.items, isEmpty, reason: 'item claims 10 bytes, 3 follow');
    expect(build([0x03, 0x41, 0x00, 0x43]).byId[2]!.items, isEmpty, reason: 'embedded 0x00 rejects the table');
  });

  test('control range (C6 20/21 f64) + help (C4 19) collect ONLY on controls, not decorations', () {
    List<int> f64rec(int id, double v) {
      final d = ByteData(8)..setFloat64(0, v);
      return [0xc6, id, 0x08, ...d.buffer.asUint8List()];
    }

    final d = dia([
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
    ]);
    final ctl = d.byId[2]!, deco = d.byId[3]!;
    expect((ctl.controlMin, ctl.controlMax, ctl.helpText), (-5.0, 10.0, 'a tooltip'));
    expect((deco.controlMin, deco.controlMax), (null, null), reason: 'range must not attach to a 0x8f decoration');
  });

  test('help text propagates up to the nearest DRAWABLE ancestor, first-wins, structures included', () {
    // carrier 0xc1 directly under a control
    final direct = dia([
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x50, 2, tag: 0x1a),
      ...bounds(10, 10, 30, 100),
      ...open(0xc1, 3, tag: 0x1b),
      ...help('hover help'),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ]);
    expect(direct.byId[3]!.absBounds, isNull, reason: 'the 0xc1 tip-strip is not drawable');
    expect(direct.byId[2]!.helpText, 'hover help');

    // skips a non-drawable 0x0c intermediate
    final skip = dia([
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
    ]);
    expect(skip.byId[3]!.absBounds, isNull);
    expect(skip.byId[3]!.helpText, isNull, reason: 'help does not land on the skipped intermediate');
    expect(skip.byId[2]!.helpText, 'deep help');

    // lands on a 0x53 structure when that is the nearest drawable
    final struct = dia([
      ...open(0x53, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0xc1, 2, tag: 0x1a),
      ...help('structure help'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(struct.byId[1]!.helpText, 'structure help');

    // never overwrites an ancestor's own help (??=)
    final own = dia([
      ...open(0x50, 1),
      ...bounds(10, 10, 30, 100),
      ...help('own help'),
      ...open(0xc1, 2, tag: 0x1a),
      ...help('child help'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(own.byId[1]!.helpText, 'own help', reason: "first-wins: the control's own help is preserved");
  });

  test('structural node fallback: unknown drawable under 0x1b with only 0x15 children -> node', () {
    final d = dia([
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
    ]);
    expect(d.byId[3]!.objectClass, HeapObjectClass.unknown, reason: '0x150 is not catalogued by code');
    expect(d.byId[3]!.category, ViObjectKind.node);
  });

  test('a BD node inherits its name from its child 0xa caption', () {
    final d = dia([
      ...open(0x7e, 1),
      ...bounds(0, 0, 400, 400),
      ...open(0x2f, 2, tag: 0x1a),
      ...bounds(10, 10, 42, 42),
      ...open(0xa, 3, tag: 0x1b),
      ...caption('Build Array'),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ]);
    expect(d.byId[3]!.label, 'Build Array', reason: 'the child 0xa carries the C4 22 caption');
    expect(d.byId[2]!.label, 'Build Array', reason: 'the caption propagates up to name the 0x2f node');
  });

  test('constValue strings: the C6 6C FF blob becomes constText (never helpText); the u8-len token neither', () {
    final blob = dia([
      ...open(0x50, 1),
      ...bounds(0, 0, 17, 80),
      ...c6blob(0x6c, 'ps2000aRunStreaming'),
      ...close(),
    ]).byId[1]!;
    expect(blob.constText, 'ps2000aRunStreaming', reason: 'raw 0x26C is a BD string constant value, not help');
    expect(blob.helpText, isNull);

    const s = 'ps2000aRunStreaming';
    final u8tok = dia([
      ...open(0x50, 1),
      ...bounds(0, 0, 17, 80),
      0xc6,
      0x6c,
      4 + s.length,
      0,
      0,
      0,
      s.length,
      ...s.codeUnits,
      ...close(),
    ]).byId[1]!;
    expect((u8tok.helpText, u8tok.constText), (null, null), reason: 'only the FF blob form is captured');
  });

  test('formatControlRange renders honestly (finite-only, inverted/±∞/NaN suppressed)', () {
    const rows = <(double?, double?, String?)>[
      (-5.0, 10.0, '-5 … 10'),
      (0.0, 2.5, '0 … 2.5'),
      (5.0, double.infinity, '≥ 5'),
      (double.negativeInfinity, 10.0, '≤ 10'),
      (double.negativeInfinity, double.infinity, null),
      (null, null, null),
      (1.0, -1.0, null), // inverted finite pair
      (5.0, 5.0, null), // degenerate equal pair
      (0.0, -0.0, null), // lo >= hi
      (0.0, double.nan, null),
      (double.nan, 10.0, null),
    ];
    for (final (lo, hi, want) in rows) {
      expect(formatControlRange(lo, hi), want, reason: '$lo … $hi');
    }
  });

  test('stripHelpMarkup removes LabVIEW markup tags but keeps real text', () {
    const rows = <(String, String)>[
      ('<B>error out</B> contains error information.', 'error out contains error information.'),
      ('<B>code</B> is 0.', 'code is 0.'),
      ('line one\n<I>line</I> two', 'line one\nline two'),
      ('plain help, no tags', 'plain help, no tags'),
      ('threshold a < 5 > 0 holds', 'threshold a < 5 > 0 holds'), // math not eaten
      ('<register>', '<register>'), // bare token is data, must not collapse to empty
      ('<default>', '<default>'),
      ('See <B>error in</B>  for details', 'See error in for details'), // no double space left behind
    ];
    for (final (input, want) in rows) {
      expect(stripHelpMarkup(input), want, reason: input);
    }
  });

  test('buildDiagram terminates on parentOid cycles and dup-oid viewport children; total over junk', () {
    final cycle = [
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
    final dupUnderViewport = [
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
    for (final records in [cycle, dupUnderViewport]) {
      final sw = Stopwatch()..start();
      expect(() => dia(records), returnsNormally);
      expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'reanchorViewport/shiftSubtree must not loop');
    }
    final junk = Uint8List.fromList([for (var i = 0; i < 400; i++) (i * 17 + 3) & 0xff]);
    final d = buildDiagram(junk);
    for (final o in d.objects) {
      o.absBounds;
      o.category;
      o.typeKind;
    }
  });
}

/// resolveDataSpaceTypes: synthetic pool + table + heaps exercising the
/// self-calibration, the agreement gate, and the dcoRef inheritance.
void resolveTypesTests() {
  ViType type(int i, ViDataType k, [String? name]) => ViType(index: i, code: 0, kind: k, name: name);
  // Pool: [0]=void, [1]=string "data in", [2]=boolean, [3]=i32.
  final pool = [
    type(0, ViDataType.voidType),
    type(1, ViDataType.string, 'data in'),
    type(2, ViDataType.boolean),
    type(3, ViDataType.i32),
  ];
  // Table with the true base at +2: entries 2..5 hold the data items.
  const table = [0, 0, 1, 2, 3, 1];

  ViHeapObject obj(int oid, int kind, {int? tdi}) {
    final o = ViHeapObject(oid: oid, kind: kind, offset: 0);
    if (tdi != null) o.typeDescIdx = tdi;
    return o;
  }

  test('calibrates the base from anchors and resolves kinds + names', () {
    final strConst = obj(1, 0x51, tdi: 0); // table[2]=1 → string ✓
    final boolConst = obj(2, 0x4f, tdi: 1); // table[3]=2 → boolean ✓
    final loopCount = obj(3, 0x24, tdi: 2); // table[4]=3 → i32 ✓
    final dco = obj(10, 0x12, tdi: 3); // table[5]=1 → string "data in"
    final terminal = obj(11, 0x16);
    terminal.typedRefs[HeapRefKind.dcoRef] = [10];
    resolveDataSpaceTypes(
      pool: pool,
      table: table,
      blockDiagrams: [
        ViDiagram(
          sectionTag: 'BDHb',
          objects: [strConst, boolConst, loopCount, terminal],
        ),
      ],
      frontPanelDiagrams: [
        ViDiagram(sectionTag: 'FPHb', objects: [dco]),
      ],
    );
    expect(strConst.typeKind, ViTypeKind.string);
    expect(boolConst.typeKind, ViTypeKind.boolean);
    expect(loopCount.dataType, ViDataType.i32);
    // The 0x16 inherited kind + name through its dcoRef.
    expect(terminal.typeKind, ViTypeKind.string);
    expect(terminal.typeName, 'data in');
  });

  test('below the agreement gate nothing resolves', () {
    // Two anchors whose expectations can never both hold at one base.
    final a = obj(1, 0x51, tdi: 0);
    final b = obj(2, 0x4f, tdi: 0); // same slot: string ≠ boolean
    resolveDataSpaceTypes(
      pool: pool,
      table: table,
      blockDiagrams: [
        ViDiagram(sectionTag: 'BDHb', objects: [a, b]),
      ],
      frontPanelDiagrams: const [],
    );
    expect(a.typeKind, ViTypeKind.unknown);
    expect(b.typeKind, ViTypeKind.unknown);
  });

  test('fewer than two anchors leaves types unresolved', () {
    final only = obj(1, 0x51, tdi: 0);
    resolveDataSpaceTypes(
      pool: pool,
      table: table,
      blockDiagrams: [
        ViDiagram(sectionTag: 'BDHb', objects: [only]),
      ],
      frontPanelDiagrams: const [],
    );
    expect(only.typeKind, ViTypeKind.unknown);
  });
}
