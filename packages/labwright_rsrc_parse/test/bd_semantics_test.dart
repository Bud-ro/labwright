import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'shape_probe.dart';
import 'test_util.dart';

List<int> memberRef(int oid) => [0x14, 0x4f, 0x01, 0xfd, ...be16(oid)];

BdDiagram bdOf(List<int> records) =>
    buildViModelFromDecoded([dsec(heapBody(records), tag: 'BDHb')]).blockDiagrams.first;

BdPlaced heapObj(
  int kind, {
  int oid = 1,
  BdObjectKind? cat,
  (int, int, int, int)? at,
  String? label,
  ViTypeKind? typeKind,
}) {
  final cls = BdObjectClass.fromCode(kind);
  final rect = at == null
      ? const HeapRect(top: 0, left: 0, bottom: 0, right: 0)
      : HeapRect(top: at.$1, left: at.$2, bottom: at.$3, right: at.$4);
  final caption = label == null ? null : HeapCaption(label);
  return switch (cat ?? cls.category) {
    BdObjectKind.node => BdNode(cls, oid: oid, bounds: rect, caption: caption),
    BdObjectKind.structure => BdStructure(cls, oid: oid, bounds: rect, caption: caption),
    BdObjectKind.terminal => BdControlBody(
      cls,
      oid: oid,
      bounds: rect,
      caption: caption,
      typeDescIdx: 0,
      typeKind: typeKind ?? ViTypeKind.unknown,
    ),
    BdObjectKind.wire => BdWire(oid: oid, bounds: rect, caption: caption),
    _ => BdUnknownPlaced(cls, oid: oid, bounds: rect, caption: caption),
  };
}

final inlinedSubViControlBd = <int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x1b, 2, tag: 0x1a),
  ...open(0x15, 3, tag: 0x1b),
  ...open(0x13, 4, tag: 0x1c),
  ...typeIndex(0),
  ...open(0x51, 5, tag: 0x1d),
  ...bounds(200, 200, 220, 300),
  ...typeIndex(0),
  ...open(0x0a, 6, tag: 0x1e),
  ...bounds(180, 200, 197, 285),
  ...caption('Requirement ID'),
  ...close(0x1e),
  ...close(0x1d),
  ...open(0x50, 7, tag: 0x1d),
  ...bounds(120, 120, 140, 160),
  ...typeIndex(0),
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
  ...open(0x2f, 21, tag: 0x1c),
  ...bounds(60, 60, 90, 90),
  ...close(0x1c),
  ...close(0x1b),
  ...open(0x1b, 12, tag: 0x1b),
  ...open(0x2f, 22, tag: 0x1c),
  ...bounds(60, 60, 90, 90),
  ...close(0x1c),
  ...open(0x2f, 32, tag: 0x1c),
  ...bounds(100, 100, 130, 130),
  ...close(0x1c),
  ...close(0x1b),
  ...open(0x1b, 13, tag: 0x1b),
  ...open(0x2f, 23, tag: 0x1c),
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
    final namePart = diagram.byOid(4)!;
    expect(namePart.label, 'x', reason: 'the scalar caption is decoded on the name part');
    expect(namePart.isLabelHidden, isTrue, reason: 'the name part is hidden');
    expect(bdDrawableObjects(diagram).map((o) => o.oid), contains(3));
  });

  test('nodeDisplayLabel prefers a real name, hints from the class catalog', () {
    final named = heapObj(0x31, cat: BdObjectKind.node, label: 'Do Thing.vi');
    expect(nodeDisplayLabel(named), (text: 'Do Thing.vi', isHint: false));
    final bare = heapObj(0x2f, cat: BdObjectKind.node);
    expect(nodeDisplayLabel(bare).isHint, isTrue);
    expect(nodeDisplayLabel(bare).text, isNotEmpty);
  });

  test('structureBadge names catalogued structures, hedges unknown ones', () {
    expect(structureBadge(heapObj(0x2c)), 'Case structure');
    expect(structureBadge(heapObj(0x7523)), 'Structure');
  });

  test('membersOf resolves declared members to DRAWN objects only', () {
    final diagram = buildBlockDiagram(
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
    expect(membersOf(diagram.byOid(2), diagram).map((m) => m.oid).toSet(), {9});
    expect(membersOf(null, diagram), isEmpty);
  });

  group('nodesWithin', () {
    BdPlaced at(int oid, BdObjectKind cat, (int, int, int, int) rect) => heapObj(
      switch (cat) {
        BdObjectKind.structure => 0x20,
        BdObjectKind.terminal => 0x50,
        _ => 0x2f,
      },
      oid: oid,
      cat: cat,
      at: rect,
    );

    test('keeps logic nodes spatially inside; drops outsiders/terminals', () {
      final loop = at(1, BdObjectKind.structure, (0, 0, 200, 200));
      final inside = at(2, BdObjectKind.node, (20, 20, 60, 100));
      final innerLoop = at(3, BdObjectKind.structure, (30, 30, 90, 150));
      final outside = at(4, BdObjectKind.node, (300, 300, 340, 400));
      final termInside = at(5, BdObjectKind.terminal, (25, 25, 35, 45));
      final within = nodesWithin(loop, [loop, inside, innerLoop, outside, termInside]);
      expect(within, containsAll([inside, innerLoop]));
      expect(within, isNot(contains(outside)));
      expect(within, isNot(contains(termInside)));
      expect(within, isNot(contains(loop)));
    });

    test('a structure with no bounds yields nothing', () {
      expect(nodesWithin(heapObj(0x53, cat: BdObjectKind.structure), const []), isEmpty);
    });

    test('an exactly-filling child is included; an exact-bounds clone is not', () {
      final frame = at(1, BdObjectKind.structure, (0, 0, 100, 100));
      final fillingClone = at(2, BdObjectKind.structure, (0, 0, 100, 100));
      final insetBody = at(3, BdObjectKind.structure, (0, 0, 100, 99));
      final within = nodesWithin(frame, [frame, fillingClone, insetBody]);
      expect(within, contains(insetBody));
      expect(within, isNot(contains(fillingClone)));
    });
  });

  test('wireframeAnnotation: catalog kind, recovered name, terminal type', () {
    final rows = <(BdObject, String)>[
      (heapObj(0x21, cat: BdObjectKind.structure), 'While Loop'),
      (heapObj(0x2c, cat: BdObjectKind.structure), 'Case structure'),
      (heapObj(0x53, cat: BdObjectKind.structure), 'Cluster'),
      (heapObj(0x2f, cat: BdObjectKind.node, label: 'PicoScope2000aOpen.vi'), 'PicoScope2000aOpen.vi'),
      (
        heapObj(0x50, cat: BdObjectKind.terminal, label: 'count', typeKind: ViTypeKind.numericInt),
        'count · numericInt',
      ),
    ];
    for (final (object, want) in rows) {
      expect(wireframeAnnotation(object), want, reason: want);
    }
  });

  group('computeBdOutline', () {
    BdObject struct(int kind) => heapObj(kind, oid: kind, cat: BdObjectKind.structure);

    test('groups structures by catalog kind; lists labeled-node captions', () {
      final outline = computeBdOutline([
        struct(0x21),
        struct(0x21),
        struct(0x2c),
        struct(0x7e),
        heapObj(0x12, oid: 10, cat: BdObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x2f, oid: 11, cat: BdObjectKind.node),
      ]);
      expect(outline.structuresByClass[BdObjectClass.whileLoop], 2);
      expect(outline.structuresByClass[BdObjectClass.caseStructure], 1);
      expect(outline.structuresByClass.containsKey(BdObjectClass.root), isFalse);
      expect(outline.labeledNodes, ['Acquire.vi']);
      expect(outline.nodeCount, 2);
      expect(outline.confidence.values.fold<int>(0, (a, b) => a + b), 5);
    });

    test('emits NO wire/edge/dataflow linkage (no-fabricated-wires)', () {
      final outline = computeBdOutline([
        struct(0x21),
        struct(0x2c),
        heapObj(0x12, oid: 10, cat: BdObjectKind.node, label: 'Acquire.vi'),
        heapObj(0x12, oid: 11, cat: BdObjectKind.node, label: 'Write.vi'),
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
