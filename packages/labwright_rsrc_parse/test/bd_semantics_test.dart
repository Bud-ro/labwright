import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

List<int> memberRef(int oid) => [0x14, 0x4f, 0x01, 0xfd, ...be16(oid)];

ViDiagram bdOf(List<int> records) =>
    buildViModelFromDecoded([dsec(heapBody(records), tag: 'BDHb')]).blockDiagrams.first;

ViHeapObject heapObj(
  int kind, {
  int oid = 1,
  ViObjectKind? cat,
  (int, int, int, int)? at,
  String? label,
  ViTypeKind? typeKind,
}) {
  final object = ViHeapObject(oid: oid, kind: kind, offset: 0);
  if (cat != null) object.category = cat;
  if (at != null) object.absBounds = HeapRect(top: at.$1, left: at.$2, bottom: at.$3, right: at.$4);
  if (label != null) object.label = label;
  if (typeKind != null) object.typeKind = typeKind;
  return object;
}

final inlinedSubViControlBd = <int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x1b, 2, tag: 0x1a),
  ...open(0x15, 3, tag: 0x1b),
  ...open(0x13, 4, tag: 0x1c),
  ...open(0x51, 5, tag: 0x1d),
  ...bounds(200, 200, 220, 300),
  ...open(0x0a, 6, tag: 0x1e),
  ...bounds(180, 200, 197, 285),
  ...caption('Requirement ID'),
  ...close(0x1e),
  ...close(0x1d),
  ...open(0x50, 7, tag: 0x1d),
  ...bounds(120, 120, 140, 160),
  ...close(0x1d),
  ...close(0x1c),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
];

final hiddenLabeledConstantBd = <int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x13, 2, tag: 0x1a),
  ...open(0x50, 3, tag: 0x1b),
  ...bounds(120, 120, 140, 160),
  ...open(0x0a, 4, tag: 0x1c),
  ...bounds(100, 120, 117, 130),
  ...caption('x'),
  ...attrU32(0xcb, 0x08),
  ...close(0x1c),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
];

List<int> stackedCaseBd(List<int> structAttrs) => <int>[
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
];

void main() {
  group('bdHiddenFrameOids', () {
    test('the decoded index hides every other frame', () {
      final hidden = bdHiddenFrameOids(bdOf(stackedCaseBd([0x24, 0x4d, 0x02])));
      expect(hidden.contains(11), isTrue);
      expect(hidden.contains(12), isTrue);
      expect(hidden.contains(13), isFalse, reason: 'dIdx=2 keeps the third frame');
    });

    test('an absent record displays the first frame', () {
      final hidden = bdHiddenFrameOids(bdOf(stackedCaseBd(const [])));
      expect(hidden.contains(11), isFalse);
      expect(hidden.contains(12), isTrue);
      expect(hidden.contains(13), isTrue);
    });

    test('an out-of-range index falls through to the content heuristic', () {
      final hidden = bdHiddenFrameOids(bdOf(stackedCaseBd([0x24, 0x4d, 0x09])));
      expect(hidden.contains(12), isFalse, reason: 'the heuristic keeps the frame with most in-box content');
      expect(hidden.contains(11), isTrue);
      expect(hidden.contains(13), isTrue);
    });
  });

  test('inlined subVI connector controls are excluded; bare constants kept', () {
    final oids = bdDrawableObjects(bdOf(inlinedSubViControlBd)).map((o) => o.oid).toSet();
    expect(oids, isNot(contains(5)));
    expect(oids, contains(7));
  });

  test('a numeric constant with a hidden name label is kept, not treated as inlined', () {
    final diagram = bdOf(hiddenLabeledConstantBd);
    final namePart = diagram.byId[4]!;
    expect(namePart.label, 'x', reason: 'the scalar caption is decoded on the name part');
    expect(namePart.isLabelHidden, isTrue, reason: 'the name part is hidden');
    expect(bdDrawableObjects(diagram).map((o) => o.oid), contains(3));
  });

  test('nodeDisplayLabel prefers a real name, hints from the class catalog', () {
    final named = heapObj(0x31, cat: ViObjectKind.node, label: 'Do Thing.vi');
    expect(nodeDisplayLabel(named), (text: 'Do Thing.vi', isHint: false));
    final bare = heapObj(0x2f, cat: ViObjectKind.node);
    expect(nodeDisplayLabel(bare).isHint, isTrue);
    expect(nodeDisplayLabel(bare).text, isNotEmpty);
  });

  test('structureBadge names catalogued structures, hedges unknown ones', () {
    expect(structureBadge(heapObj(0x2c)), 'Case structure');
    expect(structureBadge(heapObj(0x7523)), 'Structure');
  });

  test('membersOf resolves declared members to DRAWN objects only', () {
    final diagram = buildDiagram(
      heapBody(<int>[
        ...open(0x7e, 1),
        ...bounds(0, 0, 400, 400),
        ...open(0x53, 2, tag: 0x1a),
        ...bounds(10, 10, 200, 200),
        ...childRef(9),
        ...memberRef(10),
        ...childRef(11),
        ...open(0x50, 9, tag: 0x1b),
        ...bounds(20, 20, 37, 100),
        ...close(0x1b),
        ...open(0x09, 10, tag: 0x1c),
        ...bounds(40, 40, 57, 100),
        ...close(0x1c),
        ...close(0x1a),
        ...close(),
      ]),
    );
    expect(membersOf(diagram.byId[2], diagram.byId).map((m) => m.oid).toSet(), {9});
    expect(membersOf(null, diagram.byId), isEmpty);
  });

  group('nodesWithin', () {
    ViHeapObject at(int oid, ViObjectKind cat, (int, int, int, int) rect) =>
        heapObj(0x2f, oid: oid, cat: cat, at: rect);

    test('keeps logic nodes spatially inside; drops outsiders/terminals', () {
      final loop = at(1, ViObjectKind.structure, (0, 0, 200, 200));
      final inside = at(2, ViObjectKind.node, (20, 20, 60, 100));
      final innerLoop = at(3, ViObjectKind.structure, (30, 30, 90, 150));
      final outside = at(4, ViObjectKind.node, (300, 300, 340, 400));
      final termInside = at(5, ViObjectKind.terminal, (25, 25, 35, 45));
      final within = nodesWithin(loop, [loop, inside, innerLoop, outside, termInside]);
      expect(within, containsAll([inside, innerLoop]));
      expect(within, isNot(contains(outside)));
      expect(within, isNot(contains(termInside)));
      expect(within, isNot(contains(loop)));
    });

    test('a structure with no bounds yields nothing', () {
      expect(nodesWithin(heapObj(0x53, cat: ViObjectKind.structure), const []), isEmpty);
    });

    test('an exactly-filling child is included; an exact-bounds clone is not', () {
      final frame = at(1, ViObjectKind.structure, (0, 0, 100, 100));
      final fillingClone = at(2, ViObjectKind.structure, (0, 0, 100, 100));
      final insetBody = at(3, ViObjectKind.structure, (0, 0, 100, 99));
      final within = nodesWithin(frame, [frame, fillingClone, insetBody]);
      expect(within, contains(insetBody));
      expect(within, isNot(contains(fillingClone)));
    });
  });

  test('wireframeAnnotation: catalog kind, recovered name, terminal type', () {
    final rows = <(ViHeapObject, String)>[
      (heapObj(0x21, cat: ViObjectKind.structure), 'While loop'),
      (heapObj(0x2c, cat: ViObjectKind.structure), 'Case structure'),
      (heapObj(0x53, cat: ViObjectKind.structure), 'Loop (BD) / container (FP)'),
      (heapObj(0x2f, cat: ViObjectKind.node, label: 'PicoScope2000aOpen.vi'), 'PicoScope2000aOpen.vi'),
      (
        heapObj(0x50, cat: ViObjectKind.terminal, label: 'count', typeKind: ViTypeKind.numericInt),
        'count · numericInt',
      ),
    ];
    for (final (object, want) in rows) {
      expect(wireframeAnnotation(object), want, reason: want);
    }
  });

  group('computeBdOutline', () {
    ViHeapObject struct(int kind) => heapObj(kind, oid: kind, cat: ViObjectKind.structure);

    test('groups structures by catalog kind; lists labeled-node captions', () {
      final outline = computeBdOutline([
        struct(0x21),
        struct(0x21),
        struct(0x2c),
        struct(0x7e),
        heapObj(0x12, oid: 10, cat: ViObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x2f, oid: 11, cat: ViObjectKind.node),
      ]);
      expect(outline.structuresByClass[HeapObjectClass.bdWhileLoop], 2);
      expect(outline.structuresByClass[HeapObjectClass.bdStructureFrame], 1);
      expect(outline.structuresByClass.containsKey(HeapObjectClass.diagramRoot), isFalse);
      expect(outline.labeledNodes, ['Acquire.vi']);
      expect(outline.nodeCount, 2);
      expect(outline.confidence.values.fold<int>(0, (a, b) => a + b), 5);
    });

    test('emits NO wire/edge/dataflow linkage (no-fabricated-wires)', () {
      final outline = computeBdOutline([
        struct(0x21),
        struct(0x2c),
        heapObj(0x12, oid: 10, cat: ViObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x12, oid: 11, cat: ViObjectKind.node, label: 'Write.vi'),
      ]);
      final text = [
        ...outline.structuresByClass.keys.map((c) => c.label),
        ...outline.labeledNodes,
      ].join(' ').toLowerCase();
      for (final banned in ['wire', 'edge', 'dataflow', 'connect', '->', '→', 'flows to', 'wires to']) {
        expect(text.contains(banned), isFalse, reason: banned);
      }
    });
  });
}
