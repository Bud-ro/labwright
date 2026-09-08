import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'test_util.dart';

ViDiagram dia(List<int> records, {String? version}) => buildDiagram(heapBody(records), version: version);

List<int> endpoint(int oid, {int kind = 0x15}) => [...open(kind, oid, tag: 0x1a), ...close(0x1a)];

List<int> terminal(int oid, int endpointOid, (int, int, int, int) rect, {int kind = 0x22}) => [
  ...open(kind, oid, tag: 0x1a),
  ...childRef(endpointOid),
  ...c5(0x29, [...be16(rect.$1), ...be16(rect.$2), ...be16(rect.$3), ...be16(rect.$4)]),
  ...close(0x1a),
];

List<int> tunnel(int endpointOid, (int, int, int, int) rect, {int kind = 0x22}) => [
  ...terminal(endpointOid - 1, endpointOid, rect, kind: kind),
  ...endpoint(endpointOid),
];

List<int> frame(List<int> body, {int size = 100}) => [
  ...open(0x20, 1),
  ...bounds(0, 0, size, size),
  ...body,
  ...close(),
];

List<int> signal(List<int> endpointOids, [List<int> routeRecord = const []]) => [
  ...open(0x17, 9),
  for (final oid in endpointOids) ...childRef(oid),
  ...routeRecord,
  ...close(),
];

List<int> twoTunnels(List<int> table, {bool reversed = false}) => [
  ...frame([...tunnel(3, (10, 5, 19, 14)), ...tunnel(5, (40, 50, 49, 59))]),
  ...signal(reversed ? [5, 3] : [3, 5], c5(0xe7, table)),
];

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
      0xe4,
      0xea,
      ...attrU16(0xea, 1051),
      ...close(),
    ]);
    expect(d.byId[1]!.primResId, isNull, reason: 'off-class carriers are not primitive identities');
    expect(d.byId[2]!.primResId, 1051, reason: 'the u16 record wins; the flag form is inert');
  });

  test('scalar-width 0x22: printable full-width tokens are labels, everything else stays numeric', () {
    final rows = <(List<int>, String?)>[
      (attrU32(0x22, 0x584f523f), 'XOR?'),
      (attrU24(0x22, 0x496478), 'Idx'),
      (attrU16(0x22, 0x4f4b), 'OK'),
      (attrU8(0x22, 0x79), 'y'),
      (attrU16(0x22, 0x0102), null),
      (attrU16(0x22, 0x0179), null),
      (attrU16(0x22, 0xc0e9), null),
      (attrU32(0x22, 0x00424242), null),
      (attrU8(0x22, 0), null),
      ([0xe4, 0x22], null),
      ([...caption('Trigger'), ...attrU32(0x22, 0x584f523f)], 'Trigger'),
    ];
    for (final (records, want) in rows) {
      final d = dia([...open(0x0a, 1), ...records, ...close()]);
      expect(d.byId[1]!.label, want, reason: records.map((b) => b.toRadixString(16)).join(' '));
    }
  });

  test('decodeWireRoute: both headers, FF length escape, junction codes reject', () {
    final r1 = decodeWireRoute(u8([0x04, 0x08, 0x00, 0x00, 28, 12]))!;
    expect(r1.pointCount, 4);
    expect(r1.direction, WireRouteDirection.right);
    expect(r1.segmentLengths, [28, 12]);
    expect(r1.jointSigns, [1, 1]);
    expect(decodeWireRoute(u8([0x04, 0x08, 0x01, 0x00, 28, 12]))!.jointSigns, [-1, 1]);
    expect(decodeWireRoute(u8([0x02, 0x01]))!.direction, WireRouteDirection.up);
    expect(decodeWireRoute(u8([0x02, 0x02]))!.direction, WireRouteDirection.left);
    expect(decodeWireRoute(u8([0x02, 0x04]))!.direction, WireRouteDirection.down);
    expect(decodeWireRoute(u8([0x02, 0x08]))!.direction, WireRouteDirection.right);
    expect(decodeWireRoute(u8([0x02, 0x03])), isNull);
    expect(decodeWireRoute(u8([0x01]))!.pointCount, 1);
    expect(decodeWireRoute(u8([0x01, 0x08])), isNull);
    final r2 = decodeWireRoute(u8([0x03, 0x08, 0x01, 0xff, 0x01, 0x00]))!;
    expect(r2.segmentLengths, [256]);
    expect(r2.jointSigns, [-1]);
    expect(decodeWireRoute(u8([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 13, 66, 11, 247])), isNull);
    expect(decodeWireRoute(u8([0x02, 0x01, 0x00, 0x04])), isNull);
    expect(decodeWireRoute(u8([0x04])), isNull);
  });

  test('a signal captures its wire table at every width onto the wire model', () {
    final d = dia([
      ...open(0x17, 9),
      ...childRef(2),
      ...childRef(3),
      ...c5(0xe7, [0x04, 0x08, 0x00, 0x00, 28, 12]),
      ...close(),
      ...open(0x17, 10),
      0x45,
      0xe7,
      0x02,
      0x04,
      ...close(),
      ...open(0x17, 11),
      0x85,
      0xe7,
      0x03,
      0x08,
      0x01,
      0x17,
      ...close(),
      ...open(0x17, 12),
      0x25,
      0xe7,
      0x01,
      ...close(),
    ]);
    final route = d.wires[0].route!;
    expect(route.pointCount, 4);
    expect(route.direction, WireRouteDirection.right);
    expect(route.segmentLengths, [28, 12]);
    expect(route.jointSigns, [1, 1]);
    final straight = d.wires[1].route!;
    expect((straight.pointCount, straight.direction), (2, WireRouteDirection.down));
    final bend = d.wires[2].route!;
    expect((bend.pointCount, bend.direction), (3, WireRouteDirection.right));
    expect(bend.segmentLengths, [0x17]);
    expect(bend.jointSigns, [-1]);
    expect(d.wires[3].route!.pointCount, 1);
  });

  test('routePoints: the walked route closes exactly onto the far attach point or ships nothing', () {
    final good = dia(twoTunnels([0x04, 0x08, 0x00, 0x00, 20, 30]));
    expect(good.wireAttachPoint(3), (x: 9, y: 14));
    expect(good.wireAttachPoint(5), (x: 54, y: 44));
    expect(good.wires.single.routePoints, [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44), (x: 54, y: 44)]);
    expect(dia(twoTunnels([0x04, 0x08, 0x00, 0x00, 20, 29])).wires.single.routePoints, isNull);
    expect(dia(twoTunnels([0x04, 0x08, 0x00, 0x01, 20, 30])).wires.single.routePoints, isNull);
    expect(dia(twoTunnels([0x04, 0x08, 0x00, 0x00, 20, 30]), version: '8.5').wires.single.routePoints, isNull);
  });

  test('routePoints: every first-segment direction closes; zero closures drop the duplicate vertex', () {
    expect(dia(twoTunnels([0x04, 0x04, 0x00, 0x00, 30, 45])).wires.single.routePoints, [
      (x: 9, y: 14),
      (x: 9, y: 44),
      (x: 54, y: 44),
    ]);
    expect(dia(twoTunnels([0x04, 0x01, 0x01, 0x01, 30, 45], reversed: true)).wires.single.routePoints, [
      (x: 54, y: 44),
      (x: 54, y: 14),
      (x: 9, y: 14),
    ]);
    expect(dia(twoTunnels([0x03, 0x02, 0x01, 45], reversed: true)).wires.single.routePoints, [
      (x: 54, y: 44),
      (x: 9, y: 44),
      (x: 9, y: 14),
    ]);
    expect(dia(twoTunnels([0x01])).wires.single.routePoints, isNull);
  });

  test('routePoints: 1-point coincident endpoints ship a single-point route', () {
    final d = dia([
      ...frame([...tunnel(3, (10, 5, 19, 14)), ...tunnel(5, (10, 5, 19, 14))]),
      ...signal([3, 5], [0x25, 0xe7, 0x01]),
    ]);
    expect(d.wires.single.routePoints, [(x: 9, y: 14)]);
  });

  test('wireAttachPoint: own-bounds fallback is the 0x16 endpoints alone', () {
    List<int> records(int endpointKind) => [
      ...frame([...tunnel(3, (10, 5, 19, 14))]),
      ...open(endpointKind, 5),
      ...bounds(6, 100, 22, 132),
      ...close(),
      ...signal([3, 5], [0x45, 0xe7, 0x02, 0x08]),
    ];
    final leaf = dia(records(0x16));
    expect(leaf.wireAttachPoint(5), (x: 116, y: 14));
    expect(leaf.wires.single.routePoints, [(x: 9, y: 14), (x: 116, y: 14)]);
    final node = dia(records(0x15));
    expect(node.wireAttachPoint(5), isNull);
    expect(node.wires.single.routePoints, [(x: 9, y: 14), (x: 100, y: 14)]);
  });

  test('wireAttachPoint: each shift register attaches 4px interior-ward of centre', () {
    List<int> records(int terminalKind) => frame([...tunnel(3, (10, 5, 19, 14), kind: terminalKind)]);
    expect(dia(records(0x28)).wireAttachPoint(3), (x: 5, y: 14));
    expect(dia(records(0x27)).wireAttachPoint(3), (x: 13, y: 14));
    expect(dia(records(0x22)).wireAttachPoint(3), (x: 9, y: 14));
  });

  test('routePoints: a bent walk ships off either shift register at its decoded column', () {
    List<int> records(int terminalKind) => [
      ...frame([...tunnel(3, (10, 5, 19, 14), kind: terminalKind)], size: 200),
      ...open(0x15, 5),
      ...bounds(40, 60, 60, 92),
      ...close(),
      ...signal([3, 5], c5(0xe7, [0x04, 0x08, 0x00, 0x00, 55, 36])),
    ];
    expect(dia(records(0x28)).wires.single.routePoints, [(x: 5, y: 14), (x: 60, y: 14), (x: 60, y: 50)]);
    expect(dia(records(0x27)).wires.single.routePoints, [(x: 13, y: 14), (x: 68, y: 14), (x: 68, y: 50)]);
  });

  test('routePoints: a 3+-endpoint signal ships nothing even when its table decodes', () {
    final d = dia([
      ...frame([...tunnel(3, (10, 5, 19, 14)), ...endpoint(5), ...endpoint(7)]),
      ...signal([3, 5, 7], c5(0xe7, [0x03, 0x08, 0x00, 0x14])),
    ]);
    final wire = d.wires.single;
    expect(wire.route, isNotNull, reason: 'the short-form table itself decodes');
    expect(wire.routePoints, isNull, reason: 'closure is only defined for two endpoints');
    expect(wire.branchRoute, isNull, reason: 'the short form is not the extended grammar');
  });

  test('decodeWireBranchRoute: framing, FF escape, and grammar rejections', () {
    final r = decodeWireBranchRoute(u8([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 13, 66, 11, 247]))!;
    expect(r.pointCount, 5);
    expect(r.modes, [0x08, 0x05, 0x00, 0x03]);
    expect(r.segmentLengths, [13, 66, 11, 247]);
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x05, 0x03, 0xff, 0x01, 0x00, 20, 30]))!.segmentLengths, [
      256,
      20,
      30,
    ]);
    expect(decodeWireBranchRoute(u8([0x04, 0x08, 0x00, 0x00, 28, 12])), isNull);
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x09, 0x03, 10, 20, 30])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x08, 0x03, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x08, 0x05, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x05, 0x03, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x00, 0x03, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x10, 0x03, 10, 20])), isNull);
    expect(WireRouteJunction.fromCode(0x04), WireRouteJunction.cross);
    expect(WireRouteJunction.fromCode(0x07), WireRouteJunction.upDown);
    expect(WireRouteJunction.fromCode(0x03), isNull);
    expect(WireRouteJunction.fromCode(0x08), isNull);
  });

  test('walkWireBranchRoute: each junction code branches and resumes on its catalog directions', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    final t5 = walk([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 10, 20, 15, 30]);
    expect(t5.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: 20), (x: 25, y: 20)],
      [(x: 10, y: 0), (x: 40, y: 0)],
    ]);
    expect(t5.junctions, [(x: 10, y: 0)]);
    expect(t5.leaves, [(x: 25, y: 20), (x: 40, y: 0)]);
    final t6 = walk([0x04, 0x00, 0x08, 0x06, 0x03, 10, 20, 30]);
    expect(t6.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: -20)],
      [(x: 10, y: 0), (x: 40, y: 0)],
    ]);
    final t7 = walk([0x04, 0x00, 0x08, 0x07, 0x03, 10, 20, 30]);
    expect(t7.leaves, [(x: 10, y: -20), (x: 10, y: 30)]);
    final t4 = walk([0x05, 0x00, 0x08, 0x04, 0x03, 0x03, 10, 20, 30, 40]);
    expect(t4.leaves, [(x: 10, y: -20), (x: 10, y: 30), (x: 50, y: 0)]);
    expect(t4.junctions, [(x: 10, y: 0)]);
  });

  test('walkWireBranchRoute: start masks, blocked-direction substitution, negative bends', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    final tMask = walk([0x03, 0x00, 0x0c, 0x03, 15, 25]);
    expect(tMask.polylines, [
      [(x: 0, y: 0), (x: 0, y: 15)],
      [(x: 0, y: 0), (x: 25, y: 0)],
    ]);
    expect(tMask.junctions, [(x: 0, y: 0)]);
    final tSub = walk([0x05, 0x00, 0x04, 0x06, 0x00, 0x03, 10, 20, 15, 30]);
    expect(tSub.polylines, [
      [(x: 0, y: 0), (x: 0, y: 10), (x: -20, y: 10), (x: -20, y: 25)],
      [(x: 0, y: 10), (x: 30, y: 10)],
    ]);
    final tNeg = walk([0x05, 0x00, 0x08, 0x05, 0x01, 0x03, 10, 20, 15, 30]);
    expect(tNeg.polylines.first.last, (x: -5, y: 20));
  });

  test('walkWireBranchRoute: nested (depth-2) junctions resume LIFO past an exhausted junction', () {
    const start = (x: 0, y: 0);
    final t = walkWireBranchRoute(
      decodeWireBranchRoute(u8([0x06, 0x00, 0x08, 0x05, 0x05, 0x03, 0x03, 10, 20, 15, 30, 40]))!,
      start,
    );
    expect(t.junctions, [(x: 10, y: 0), (x: 10, y: 20)]);
    expect(t.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: 20), (x: 10, y: 35)],
      [(x: 10, y: 20), (x: 40, y: 20)],
      [(x: 10, y: 0), (x: 50, y: 0)],
    ]);
    expect(t.leaves, [(x: 10, y: 35), (x: 40, y: 20), (x: 50, y: 0)]);
  });

  test('walkWireBranchRoute: 3-bit start mask forks three arms; substitution across codes and axes', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    final t3 = walk([0x04, 0x00, 0x0d, 0x03, 0x03, 10, 20, 30]);
    expect(t3.junctions, [(x: 0, y: 0)]);
    expect(t3.leaves, [(x: 0, y: -10), (x: 0, y: 20), (x: 30, y: 0)]);
    expect(walk([0x04, 0x00, 0x0e, 0x03, 0x03, 10, 20, 30]).leaves, [(x: -10, y: 0), (x: 0, y: 20), (x: 30, y: 0)]);
    final tCross = walk([0x05, 0x00, 0x01, 0x04, 0x03, 0x03, 10, 20, 30, 40]);
    expect(tCross.junctions, [(x: 0, y: -10)]);
    expect(tCross.leaves, [(x: 0, y: -30), (x: -30, y: -10), (x: 40, y: -10)]);
    final tUpDown = walk([0x04, 0x00, 0x01, 0x07, 0x03, 10, 20, 30]);
    expect(tUpDown.leaves, [(x: 0, y: -30), (x: -30, y: -10)]);
  });

  test('routeTree gate: an unanchored origin reverse-solves; a leaf-count mismatch ships nothing', () {
    List<int> records(int firstEndpoint, List<int> table) => [
      ...frame([
        ...tunnel(3, (10, 5, 19, 14)),
        ...tunnel(5, (40, 25, 49, 34)),
        ...tunnel(7, (10, 50, 19, 59)),
        ...endpoint(8),
      ]),
      ...signal([firstEndpoint, 5, 7], c5(0xe7, table)),
    ];
    final noOrigin = dia(records(8, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])).wires.single;
    expect(noOrigin.branchRoute, isNotNull);
    expect(noOrigin.routeTreeFidelity, WireRouteFidelity.walked);
    expect(noOrigin.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(noOrigin.routeTree!.junctions, [(x: 29, y: 14)]);
    final fewLeaves = dia(records(3, [0x03, 0x00, 0x08, 0x00, 20, 30])).wires.single;
    expect(fewLeaves.branchRoute, isNotNull);
    expect(fewLeaves.routeTree, isNull);
  });

  test('routeTree reverse-solve gate: an ambiguous translation ships nothing', () {
    final records = [
      ...frame([
        ...tunnel(3, (40, 56, 49, 65)),
        ...endpoint(5),
        ...endpoint(7),
      ]),
      ...signal([5, 3, 7], c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])),
    ];
    final wire = dia(records).wires.single;
    expect(wire.branchRoute, isNotNull);
    expect(wire.routeTree, isNull);
  });

  test('routeTree reverse-solve gate: a candidate on the head box far edge does not block the interior solve', () {
    List<int> records(int attachY) => [
      ...frame([
        ...tunnel(3, (attachY - 4, 56, attachY + 5, 65)),
        ...endpoint(5),
        ...endpoint(7),
      ]),
      ...signal([5, 3, 7], c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])),
    ];
    for (final (attachY, origin) in <(int, ViPoint?)>[
      (99, null),
      (100, (x: 40, y: 70)),
      (101, (x: 40, y: 71)),
    ]) {
      final wire = dia(records(attachY)).wires.single;
      expect(wire.routeTree?.polylines.first.first, origin, reason: 'attach y $attachY');
    }
  });

  test('routeTree: a fully-anchored branching signal ships exactly-closing trees only', () {
    List<int> records({required int thirdLeft}) => [
      ...frame([
        ...tunnel(3, (10, 5, 19, 14)),
        ...tunnel(5, (40, 25, 49, 34)),
        ...tunnel(7, (10, thirdLeft, 19, thirdLeft + 9)),
      ]),
      ...signal([3, 5, 7], c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])),
    ];
    final good = dia(records(thirdLeft: 50)).wires.single;
    expect(good.route, isNull, reason: 'the extended form is not the two-endpoint grammar');
    expect(good.branchRoute, isNotNull);
    expect(good.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(good.routeTree!.junctions, [(x: 29, y: 14)]);
    final miss = dia(records(thirdLeft: 51)).wires.single;
    expect(miss.branchRoute, isNotNull);
    expect(miss.routeTree, isNull);
  });

  test('walkOneAnchoredRoute: forward, reverse, into-node, and reject cases', () {
    ViWireRoute makeRoute(int pointCount, WireRouteDirection direction, List<int> signs, List<int> lengths) =>
        ViWireRoute(pointCount: pointCount, direction: direction, segmentLengths: lengths, jointSigns: signs);
    const box = HeapRect(top: 40, left: 40, bottom: 60, right: 60);
    const boxRightOfAnchor = HeapRect(top: 40, left: 100, bottom: 60, right: 120);

    void check(
      String name,
      ViWireRoute route,
      ViPoint anchor, {
      int anchoredIndex = 0,
      HeapRect farBox = box,
      List<ViPoint>? points,
      ViStep? step,
    }) {
      final walked = walkOneAnchoredRoute(route, anchor: anchor, anchoredIndex: anchoredIndex, farBox: farBox);
      expect(walked?.points, points, reason: name);
      expect(walked?.closingStep, step, reason: name);
    }

    check(
      'forward, one bend: closing run drops onto the box top edge, no into-node step',
      makeRoute(3, WireRouteDirection.right, [1], [30]),
      (x: 10, y: 20),
      points: [(x: 10, y: 20), (x: 40, y: 20), (x: 40, y: 40)],
    );
    check(
      'forward, straight: the whole run is the closing run onto the near edge',
      makeRoute(2, WireRouteDirection.right, const [], const []),
      (x: 5, y: 50),
      points: [(x: 5, y: 50), (x: 40, y: 50)],
    );
    check(
      'reverse, straight: the head rides the far (right) edge, storage order',
      makeRoute(2, WireRouteDirection.right, const [], const []),
      (x: 100, y: 50),
      anchoredIndex: 1,
      points: [(x: 59, y: 50), (x: 100, y: 50)],
    );
    check(
      'reverse, bent: departing and closing axes differ — underdetermined, null',
      makeRoute(3, WireRouteDirection.right, [1], [30]),
      (x: 100, y: 50),
      anchoredIndex: 1,
    );
    check(
      'forward closing run would double back against the stored sign: null',
      makeRoute(3, WireRouteDirection.right, [1], [30]),
      (x: 10, y: 80),
    );
    check(
      'terminus row outside the box vertical span points beside the node: null',
      makeRoute(3, WireRouteDirection.down, [1], [160]),
      (x: 30, y: 40),
    );
    check(
      'reverse straight with the box on the wrong side of the anchor: null',
      makeRoute(2, WireRouteDirection.right, const [], const []),
      (x: 30, y: 50),
      anchoredIndex: 1,
      farBox: boxRightOfAnchor,
    );
    check(
      'zero-length close ends on the edge: no duplicate vertex and no step',
      makeRoute(3, WireRouteDirection.right, [1], [30]),
      (x: 10, y: 40),
      points: [(x: 10, y: 40), (x: 40, y: 40)],
    );
    check(
      'into-node +x',
      makeRoute(4, WireRouteDirection.right, [1], [35, 5]),
      (x: 10, y: 50),
      points: [(x: 10, y: 50), (x: 45, y: 50), (x: 45, y: 55)],
      step: (dx: 1, dy: 0),
    );
    check(
      'into-node +y',
      makeRoute(4, WireRouteDirection.down, [1], [15, 5]),
      (x: 50, y: 35),
      points: [(x: 50, y: 35), (x: 50, y: 50), (x: 55, y: 50)],
      step: (dx: 0, dy: 1),
    );
    check(
      'into-node -x',
      makeRoute(4, WireRouteDirection.left, [-1], [35, 5]),
      (x: 90, y: 50),
      points: [(x: 90, y: 50), (x: 55, y: 50), (x: 55, y: 45)],
      step: (dx: -1, dy: 0),
    );
    check(
      'into-node -y',
      makeRoute(4, WireRouteDirection.up, [-1], [15, 5]),
      (x: 50, y: 70),
      points: [(x: 50, y: 70), (x: 50, y: 55), (x: 45, y: 55)],
      step: (dx: 0, dy: -1),
    );
    check(
      'into-node reject: bend beyond the far edge has no node to enter',
      makeRoute(4, WireRouteDirection.right, [1], [60, 5]),
      (x: 10, y: 50),
    );
    check('into-node reject: bend row beyond the bottom edge', makeRoute(4, WireRouteDirection.down, [1], [60, 5]), (
      x: 50,
      y: 10,
    ));
    check(
      'into-node reject: bend at the exclusive right edge (x = 60) is outside',
      makeRoute(4, WireRouteDirection.right, [1], [50, 5]),
      (x: 10, y: 50),
    );
    check(
      'into-node reject: bend at the last interior column but the step would exit',
      makeRoute(4, WireRouteDirection.right, [1], [49, 5]),
      (x: 10, y: 50),
    );
    check(
      'into-node reject: a bendless route has no drawable segment to ship',
      makeRoute(2, WireRouteDirection.right, const [], const []),
      (x: 45, y: 50),
    );
    check(
      'forward reject: a bend column on the exclusive right edge (x = 60) is beside the box',
      makeRoute(3, WireRouteDirection.right, [1], [50]),
      (x: 10, y: 20),
    );
    check(
      'forward reject: a terminus row on the exclusive bottom edge (y = 60) is under the box',
      makeRoute(3, WireRouteDirection.down, [1], [40]),
      (x: 20, y: 20),
    );
    check(
      'reverse reject: a head row on the exclusive bottom edge is under the box',
      makeRoute(2, WireRouteDirection.right, const [], const []),
      (x: 100, y: 60),
      anchoredIndex: 1,
    );
  });

  test('routePoints walked tier: one exact anchor ships the walk; the far plain node rides its box', () {
    List<int> records(List<int> endpointOids, List<int> table, (int, int, int, int) nodeBox) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...tunnel(3, (10, 5, 19, 14)),
      ...open(0x2f, 6, tag: 0x1a),
      ...bounds(nodeBox.$1, nodeBox.$2, nodeBox.$3, nodeBox.$4),
      ...open(0x15, 7, tag: 0x1b),
      ...close(0x1b),
      ...close(0x1a),
      ...signal(endpointOids, c5(0xe7, table)),
    ];
    final fwdDia = dia(records([3, 7], [0x03, 0x08, 0x00, 30], (40, 30, 60, 90)));
    expect(fwdDia.wireAttachPoint(3), (x: 9, y: 14));
    expect(fwdDia.wireAttachPoint(7), isNull);
    expect(fwdDia.wires.single.routePoints, [(x: 9, y: 14), (x: 39, y: 14), (x: 39, y: 40)]);
    expect(fwdDia.wires.single.routePointsFidelity, WireRouteFidelity.walked);
    final rev = dia(records([7, 3], [0x02, 0x02], (5, 40, 25, 90))).wires.single;
    expect(rev.routePoints, [(x: 40, y: 14), (x: 9, y: 14)]);
    final revBent = dia(records([7, 3], [0x03, 0x02, 0x00, 30], (5, 40, 25, 90))).wires.single;
    expect(revBent.routePoints, isNull);
    final revSlack = dia(
      records([7, 3], [0x04, 0x02, 0x00, 0x01, 10, 6], (5, 40, 25, 90)),
    ).wires.single;
    expect(revSlack.routePoints, [
      (x: 40, y: 8),
      (x: 30, y: 8),
      (x: 30, y: 14),
      (x: 9, y: 14),
    ]);
    expect(revSlack.routePointsFidelity, WireRouteFidelity.walked);
    expect(revSlack.routeHeadSlack, (dx: 1, dy: 0));
    final revSlackZero = dia(
      records([7, 3], [0x04, 0x02, 0x00, 0x01, 31, 6], (5, 40, 25, 90)),
    ).wires.single;
    expect(revSlackZero.routePoints, [
      (x: 40, y: 8),
      (x: 9, y: 8),
      (x: 9, y: 14),
      (x: 9, y: 14),
    ]);
    expect(revSlackZero.routeHeadSlack, (dx: 1, dy: 0));
  });

  test('routePoints walked tier: a coarse anchor or no anchor ships nothing', () {
    List<int> bothBare(List<int> table) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...endpoint(3),
      ...open(0x2f, 6, tag: 0x1a),
      ...bounds(40, 40, 60, 90),
      ...open(0x15, 7, tag: 0x1b),
      ...close(0x1b),
      ...close(0x1a),
      ...signal([3, 7], c5(0xe7, table)),
    ];
    expect(dia(bothBare([0x03, 0x08, 0x00, 30])).wires.single.routePoints, isNull);

    final constAnchor = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x15, 3, tag: 0x1a),
      ...open(0x13, 10, tag: 0x1b),
      ...open(0x2f, 11, tag: 0x1c),
      ...bounds(10, 10, 26, 42),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x2f, 6, tag: 0x1a),
      ...bounds(40, 40, 60, 90),
      ...open(0x15, 7, tag: 0x1b),
      ...close(0x1b),
      ...close(0x1a),
      ...signal([3, 7], c5(0xe7, [0x02, 0x08])),
    ]);
    expect(constAnchor.wireAttachPoint(3), isNotNull, reason: 'the constant shell resolves an attach point');
    expect(constAnchor.wires.single.routePoints, isNull, reason: 'but a coarse constant-shell anchor is withheld');
  });

  test('routeTree walked tier: origin-anchored, contradiction-free trees ship; a missed resolved leaf does not', () {
    List<int> records({required bool bareSecond, int thirdLeft = 50}) => [
      ...frame([
        ...tunnel(3, (10, 5, 19, 14)),
        if (bareSecond) ...endpoint(5) else ...tunnel(5, (40, 25, 49, 34)),
        ...tunnel(7, (10, thirdLeft, 19, thirdLeft + 9)),
      ], size: 200),
      ...signal([3, 5, 7], c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])),
    ];
    final walked = dia(records(bareSecond: true)).wires.single;
    expect(walked.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(walked.routeTree!.junctions, [(x: 29, y: 14)]);
    expect(walked.routeTreeFidelity, WireRouteFidelity.walked);
    final closed = dia(records(bareSecond: false)).wires.single;
    expect(closed.routeTree, isNotNull);
    expect(closed.routeTreeFidelity, WireRouteFidelity.closed);
    final contradiction = dia(records(bareSecond: true, thirdLeft: 51)).wires.single;
    expect(contradiction.routeTree, isNull);
  });

  test('routeTree walked tier: two resolved endpoints cannot share one walked leaf', () {
    final d = dia([
      ...frame([
        ...tunnel(3, (10, 5, 19, 14)),
        ...tunnel(5, (10, 50, 19, 59)),
        ...tunnel(7, (10, 50, 19, 59)),
      ], size: 200),
      ...signal([3, 5, 7], c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])),
    ]);
    expect(d.wireAttachPoint(5), (x: 54, y: 14));
    expect(d.wireAttachPoint(7), (x: 54, y: 14));
    expect(d.wires.single.routeTree, isNull);
  });

  test('endpointTerminalBounds: attach rect = termBounds + enclosing frame origin', () {
    final records = [
      ...open(0x20, 1),
      ...bounds(100, 50, 200, 150),
      ...tunnel(3, (10, 5, 19, 14)),
      ...endpoint(4, kind: 0x16),
      ...close(),
      ...signal([3, 4]),
    ];
    final d = dia(records);
    expect(d.endpointTerminal(3)!.oid, 2);
    final pos = d.endpointTerminalBounds(3)!;
    expect((pos.top, pos.left, pos.bottom, pos.right), (110, 55, 119, 64));
    final wire = d.wires.single;
    expect((wire.endpointAttachRects.first!.top, wire.endpointAttachRects.first!.left), (110, 55));
    expect(wire.endpointAttachRects.last, isNull, reason: 'no terminal names endpoint 4');
    expect(d.endpointTerminalBounds(2), isNull, reason: 'gated to the endpoint DCO kinds');
    expect(d.endpointTerminal(1), isNull);
    expect(dia(records, version: '8.5').endpointTerminalBounds(3), isNull);
    expect(dia(records, version: '8.6').endpointTerminalBounds(3), isNotNull);
    expect(ViWire(signalOid: 9, endpointOids: [3, 4], endpointAnchors: [null, null]).endpointAttachRects, [
      null,
      null,
    ]);
  });

  test('endpointTerminal: an endpoint two terminals claim resolves to nothing', () {
    final d = dia(
      frame([...terminal(2, 3, (0, 0, 9, 9)), ...terminal(5, 3, (1, 1, 9, 9)), ...endpoint(3)]),
    );
    expect(d.endpointTerminal(3), isNull, reason: 'ambiguous claims are dropped, never guessed (corpus: 0)');
    expect(d.endpointTerminalBounds(3), isNull);
  });

  test('isLabelHidden: objFlags bit 0x08 on label parts only', () {
    final d = dia([
      ...open(0xa, 1),
      ...caption('hidden'),
      ...attrU24(0xcb, 0x17114a),
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
      ...attrU32(0x4d, 0x80000002),
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

  test('displayedFrameIndex: the stored index resolved against the frames that exist', () {
    List<int> caseWithFrames(int oid, int? dIdx, int frames) => [
      ...open(0x2c, oid),
      if (dIdx != null) ...attrU8(0x4d, dIdx),
      for (var i = 0; i < frames; i++) ...[...open(kViFrameCode, oid * 10 + i), ...close()],
      ...close(),
    ];
    final d = dia([
      ...caseWithFrames(1, 1, 2),
      ...caseWithFrames(2, 5, 2),
      ...caseWithFrames(3, null, 2),
      ...caseWithFrames(4, 1, 0),
      ...open(0x50, 5),
      ...close(),
    ]);
    expect(d.framesOf(d.byId[1]!).map((f) => f.oid), [10, 11]);
    expect(d.displayedFrameIndex(d.byId[1]!), 1);
    expect(d.displayedFrameIndex(d.byId[2]!), isNull, reason: 'index past the frame count names no frame');
    expect(d.displayedFrameIndex(d.byId[3]!), 0, reason: 'absent record displays the first frame');
    expect(d.displayedFrameIndex(d.byId[4]!), isNull, reason: 'no frames, nothing to display');
    expect(d.displayedFrameIndex(d.byId[5]!), isNull, reason: 'not a stacked multi-frame class');
  });

  test('an owned label composes against its owner even when the owner bounds record trails it', () {
    final d = dia([
      ...open(0x20, 1),
      ...bounds(100, 200, 400, 700),
      ...open(0x2c, 2, tag: 0x1a),
      ...open(0xa, 3, tag: 0x1b),
      ...bounds(-17, 0, 0, 75),
      ...caption('Reflect Input?'),
      ...close(0x1b),
      ...bounds(50, 40, 120, 130),
      ...close(0x1a),
      ...close(),
    ]);
    final label = d.byId[3]!.absBounds!;
    expect([label.top, label.left], [133, 240], reason: 'owner abs (150,240) + local (-17,0)');
  });

  test('PrimOp catalog: unique ids, lookup round-trip', () {
    final ids = PrimOp.values.map((op) => op.id).toSet();
    expect(ids.length, PrimOp.values.length, reason: 'catalog ids are unique');
    for (final op in PrimOp.values) {
      expect(PrimOp.fromId(op.id), op);
      expect(op.opName, isNotEmpty);
    }
    expect(PrimOp.fromId(9999), isNull);
    expect(PrimOp.add.slug, 'add');
    expect(PrimOp.toLongInteger.slug, 'to-long-integer');
    expect(PrimOp.greaterOrEqualToZero.slug, 'greater-or-equal-to-0');
    for (final op in PrimOp.values) {
      expect(RegExp(r'^[a-z0-9-]+$').hasMatch(op.slug), isTrue, reason: op.opName);
    }
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
    final viewport = d.byId[3]!.absBounds!;
    final upper = d.byId[4]!.absBounds!, lower = d.byId[5]!.absBounds!;
    expect([upper.top, upper.left], [210, 55], reason: '#4 re-anchored to the viewport origin');
    expect(lower.top, 248, reason: '#5 sits 38px below #4 (-262 vs -300) -> 210+38');
    for (final control in [upper, lower]) {
      final centre = (control.top + control.bottom) ~/ 2;
      expect(centre >= viewport.top && centre <= viewport.bottom, isTrue, reason: 'control center inside viewport');
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
      ViObjectKind.node: [
        0x12, 0x2f, 0x31, 0x63, 0x8c, 0x3a, 0xd6, 0x32, 0xc5, 0x104, 0x44, 0x3e, 0x34, 0xa9, 0x93, 0x172, //
        0x6c, 0x36, 0x153, 0x6a, 0xbd, 0x114, 0xb6, 0xb9, 0x48, 0xeb, 0x103, 0x14a, 0x124, //
        0x150, 0x14f, 0x152,
      ],
      ViObjectKind.terminal: [0x68, 0x16, 0x95, 0x55, 0x4e, 0x10c, 0xc2],
      ViObjectKind.structure: [0x53, 0x2c, 0xca, 0x29, 0xd5, 0x121, 0x20, 0x21, 0xcd, 0x14d],
      ViObjectKind.decoration: [0x177],
    };
    byCategory.forEach((category, kinds) {
      for (final k in kinds) {
        expect(
          classifyObject(objectClass: HeapObjectClass.fromCode(k), termCount: 0),
          category,
          reason: '0x${k.toRadixString(16)}',
        );
      }
    });
    expect(
      classifyObject(objectClass: HeapObjectClass.numericControl, termCount: 2),
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

    final struct = dia([
      ...open(0x53, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0xc1, 2, tag: 0x1a),
      ...help('structure help'),
      ...close(0x1a),
      ...close(),
    ]);
    expect(struct.byId[1]!.helpText, 'structure help');

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
      ...open(0x170, 3, tag: 0x1b),
      ...bounds(10, 10, 42, 42),
      ...open(0x15, 4, tag: 0x1c),
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...close(),
    ]);
    expect(d.byId[3]!.objectClass, HeapObjectClass.unknown, reason: '0x170 is not catalogued by code');
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

  test(
    'constValue strings: both validated forms (C6 6C FF blob, short u8-len u32-string) become constText, never helpText',
    () {
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
      expect(
        (u8tok.helpText, u8tok.constText),
        (null, s),
        reason: 'the short validated u32-string form is a constant value too',
      );
    },
  );

  test('formatControlRange renders honestly (finite-only, inverted/±∞/NaN suppressed)', () {
    const rows = <(double?, double?, String?)>[
      (-5.0, 10.0, '-5 … 10'),
      (0.0, 2.5, '0 … 2.5'),
      (5.0, double.infinity, '≥ 5'),
      (double.negativeInfinity, 10.0, '≤ 10'),
      (double.negativeInfinity, double.infinity, null),
      (null, null, null),
      (1.0, -1.0, null),
      (5.0, 5.0, null),
      (0.0, -0.0, null),
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
      ('threshold a < 5 > 0 holds', 'threshold a < 5 > 0 holds'),
      ('<register>', '<register>'),
      ('<default>', '<default>'),
      ('See <B>error in</B>  for details', 'See error in for details'),
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

void resolveTypesTests() {
  ViType type(int i, ViDataType k, [String? name]) => ViType(index: i, code: 0, kind: k, name: name);
  final pool = [
    type(0, ViDataType.voidType),
    type(1, ViDataType.string, 'data in'),
    type(2, ViDataType.boolean),
    type(3, ViDataType.i32),
  ];
  const table = [0, 0, 1, 2, 3, 1];
  final dthp = decodeDataTypeHeap(Uint8List.fromList([0, 4, 0, 3]))!;

  ViHeapObject obj(int oid, int kind, {int? tdi}) {
    final o = ViHeapObject(oid: oid, kind: kind, offset: 0);
    if (tdi != null) o.typeDescIdx = tdi;
    return o;
  }

  ViDiagram bd(List<ViHeapObject> objects) => ViDiagram(sectionTag: 'BDHb', objects: objects);

  test('DTHP base: [count][firstTopLevelIndex] locates the heap index space', () {
    expect((dthp.heapTypeCount, dthp.firstTopLevelIndex, dthp.viTypeIndexBase), (4, 3, 1));
    expect(dthp.firstTopLevelIndex + dthp.heapTypeCount - 1, table.length);
  });

  test('resolves kinds + names at the DTHP base', () {
    final strConst = obj(1, 0x51, tdi: 1);
    final boolConst = obj(2, 0x4f, tdi: 2);
    final loopCount = obj(3, 0x24, tdi: 3);
    final dco = obj(10, 0x12, tdi: 4);
    final terminal = obj(11, 0x16);
    terminal.typedRefs[HeapRefKind.dcoRef] = [10];
    resolveDataSpaceTypes(
      pool: pool,
      table: table,
      typeIndexBase: dthp.viTypeIndexBase,
      blockDiagrams: [
        bd([strConst, boolConst, loopCount, terminal]),
      ],
      frontPanelDiagrams: [
        ViDiagram(sectionTag: 'FPHb', objects: [dco]),
      ],
    );
    expect(strConst.typeKind, ViTypeKind.string);
    expect(boolConst.typeKind, ViTypeKind.boolean);
    expect(loopCount.dataType, ViDataType.i32);
    expect(terminal.typeKind, ViTypeKind.string);
    expect(terminal.typeName, 'data in');
  });

  test('no base leaves every type unresolved', () {
    final only = obj(1, 0x51, tdi: 1);
    resolveDataSpaceTypes(
      pool: pool,
      table: table,
      typeIndexBase: null,
      blockDiagrams: [
        bd([only]),
      ],
      frontPanelDiagrams: const [],
    );
    expect(only.typeKind, ViTypeKind.unknown);
  });
}
