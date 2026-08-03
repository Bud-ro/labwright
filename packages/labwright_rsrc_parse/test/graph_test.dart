import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
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

ViDiagram dia(List<int> records, {String? version}) =>
    buildDiagram(u8([0, 0, 0, records.length, ...records]), version: version);

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

  test('scalar-width 0x22: printable full-width tokens are labels, everything else stays numeric', () {
    final rows = <(List<int>, String?)>[
      (attrU32(0x22, 0x584f523f), 'XOR?'), // big-endian reading order, width 4
      (attrU24(0x22, 0x496478), 'Idx'), // width 3
      (attrU16(0x22, 0x4f4b), 'OK'), // width 2
      (attrU8(0x22, 0x79), 'y'), // width 1
      (attrU16(0x22, 0x0102), null), // leading byte printable? no: first byte non-printable
      (attrU16(0x22, 0x0179), null), // low byte 'y' printable, high byte 0x01 not: stays numeric
      (attrU16(0x22, 0xc0e9), null), // high-bit Latin-1 bytes are not ASCII glyphs
      (attrU32(0x22, 0x00424242), null), // width-inconsistent: "BBB" (3) in a 4-byte field is a number
      (attrU8(0x22, 0), null), // zero = empty
      ([0xe4, 0x22], null), // flag width carries no text bytes
      ([...caption('Trigger'), ...attrU32(0x22, 0x584f523f)], 'Trigger'), // first-wins over the scalar form
    ];
    for (final (records, want) in rows) {
      final d = dia([...open(0x0a, 1), ...records, ...close()]);
      expect(d.byId[1]!.label, want, reason: records.map((b) => b.toRadixString(16)).join(' '));
    }
  });

  test('corpus pin: crc8 scalar-width caption', () {
    if (!corpusViDir.existsSync()) {
      markTestSkipped('corpus not fetched');
      return;
    }
    // crc8.png stores oid221's label as `84 22 58 4F 52 3F` — the 4-byte
    // scalar form of raw 0x022 — on a label part under a case structure.
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    final vi = extractSnippetVi(crc8.readAsBytesSync())!;
    final o = buildViModel(vi).blockDiagrams.single.byId[221]!;
    expect((o.kind, o.label, o.parentOid), (0x0a, 'XOR?', 220));
  });

  test('decodeWireRoute: both headers, FF length escape, junction codes reject', () {
    // basic.png's x-input wire: 4 points, right then down, H 28 / V 12.
    final r1 = decodeWireRoute(u8([0x04, 0x08, 0x00, 0x00, 28, 12]))!;
    expect(r1.pointCount, 4);
    expect(r1.direction, WireRouteDirection.right);
    expect(r1.segmentLengths, [28, 12]);
    expect(r1.jointSigns, [1, 1]);
    // basic.png's y-input wire: same lengths, second segment runs up.
    expect(decodeWireRoute(u8([0x04, 0x08, 0x01, 0x00, 28, 12]))!.jointSigns, [-1, 1]);
    // Every one-hot direction code decodes; anything else is no direction.
    expect(decodeWireRoute(u8([0x02, 0x01]))!.direction, WireRouteDirection.up);
    expect(decodeWireRoute(u8([0x02, 0x02]))!.direction, WireRouteDirection.left);
    expect(decodeWireRoute(u8([0x02, 0x04]))!.direction, WireRouteDirection.down);
    expect(decodeWireRoute(u8([0x02, 0x08]))!.direction, WireRouteDirection.right);
    expect(decodeWireRoute(u8([0x02, 0x03])), isNull);
    // The 1-point table (coincident endpoints) is the single byte 01.
    expect(decodeWireRoute(u8([0x01]))!.pointCount, 1);
    expect(decodeWireRoute(u8([0x01, 0x08])), isNull);
    // FF escape: a 256-unit segment.
    final r2 = decodeWireRoute(u8([0x03, 0x08, 0x01, 0xff, 0x01, 0x00]))!;
    expect(r2.segmentLengths, [256]);
    expect(r2.jointSigns, [-1]);
    // The extended `[n][00]…` multi-endpoint branching form is not decoded:
    // null, never a guess.
    expect(decodeWireRoute(u8([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 13, 66, 11, 247])), isNull);
    // Length-count mismatches and trailing junk are malformed, not guessed.
    expect(decodeWireRoute(u8([0x02, 0x01, 0x00, 0x04])), isNull);
    expect(decodeWireRoute(u8([0x04])), isNull);
  });

  test('a signal captures its wire table at every width onto the wire model', () {
    final d = dia([
      ...open(0x17, 9), // container width
      ...hx('14 19 01 fd 0002'),
      ...hx('14 19 01 fd 0003'),
      ...c5(0xe7, [0x04, 0x08, 0x00, 0x00, 28, 12]),
      ...close(),
      ...open(0x17, 10), // u16 scalar (op 45 = raw 0x1E7) = the 2-byte straight table [02][dir]
      0x45, 0xe7, 0x02, 0x04,
      ...close(),
      ...open(0x17, 11), // 4-byte scalar (op 85) = the one-bend table [03][dir][sign][len]
      0x85, 0xe7, 0x03, 0x08, 0x01, 0x17,
      ...close(),
      ...open(0x17, 12), // u8 scalar (op 25) = the 1-point table [01]
      0x25, 0xe7, 0x01,
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
    // Two structure tunnels on one frame; the signal's stored route walks
    // right 20 from the first tunnel's attach centre (9,14), turns down 30,
    // and the implied closing segment lands on the second tunnel's attach
    // centre (54,44).
    List<int> records(List<int> table) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // attach (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a),
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 40, 0, 50, 0, 49, 0, 59]), // attach (54, 44)
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...c5(0xe7, table),
      ...close(),
    ];
    final good = dia(records([0x04, 0x08, 0x00, 0x00, 20, 30]));
    expect(good.wireAttachPoint(3), (x: 9, y: 14));
    expect(good.wireAttachPoint(5), (x: 54, y: 44));
    expect(good.wires.single.routePoints, [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44), (x: 54, y: 44)]);
    // A walk whose perpendicular lands 1 px off the far attach point ships
    // nothing — never force-closed.
    expect(dia(records([0x04, 0x08, 0x00, 0x00, 20, 29])).wires.single.routePoints, isNull);
    // A closing segment contradicting the stored final sign ships nothing.
    expect(dia(records([0x04, 0x08, 0x00, 0x01, 20, 30])).wires.single.routePoints, isNull);
    // Pre-8.6 files stay null (old coordinate space).
    expect(dia(records([0x04, 0x08, 0x00, 0x00, 20, 30]), version: '8.5').wires.single.routePoints, isNull);
  });

  test('routePoints: every first-segment direction closes; zero closures drop the duplicate vertex', () {
    // The same two tunnels — attach (9,14) and (54,44) — wired in either
    // direction, with the signal's endpoint order picking the walk origin.
    List<int> records(List<int> table, {bool reversed = false}) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // attach (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a),
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 40, 0, 50, 0, 49, 0, 59]), // attach (54, 44)
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx(reversed ? '14 19 01 fd 0005' : '14 19 01 fd 0003'),
      ...hx(reversed ? '14 19 01 fd 0003' : '14 19 01 fd 0005'),
      ...c5(0xe7, table),
      ...close(),
    ];
    // Down-first, and the walk ends ON the far attach point: the implied
    // closing run is zero-length, so the duplicate terminal vertex is
    // dropped (3 points for a 4-point table).
    expect(dia(records([0x04, 0x04, 0x00, 0x00, 30, 45])).wires.single.routePoints, [
      (x: 9, y: 14),
      (x: 9, y: 44),
      (x: 54, y: 44),
    ]);
    // Up-first from the far tunnel back to the near one (same shape).
    expect(dia(records([0x04, 0x01, 0x01, 0x01, 30, 45], reversed: true)).wires.single.routePoints, [
      (x: 54, y: 44),
      (x: 54, y: 14),
      (x: 9, y: 14),
    ]);
    // Left-first with a real (nonzero) closing run.
    expect(dia(records([0x03, 0x02, 0x01, 45], reversed: true)).wires.single.routePoints, [
      (x: 54, y: 44),
      (x: 9, y: 44),
      (x: 9, y: 14),
    ]);
    // A 1-point table ships iff the two attach points coincide.
    expect(dia(records([0x01])).wires.single.routePoints, isNull);
  });

  test('routePoints: 1-point coincident endpoints ship a single-point route', () {
    final d = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]),
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a), // a second terminal over the same rect
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]),
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      0x25, 0xe7, 0x01, // the u8-scalar 1-point table
      ...close(),
    ]);
    expect(d.wires.single.routePoints, [(x: 9, y: 14)]);
  });

  test('wireAttachPoint: own-bounds fallback is the 0x16 endpoints alone', () {
    // A tunnel-anchored straight wire into a bounded endpoint: with a 0x16
    // it attaches at the box's floored centre and the closed route ships. A
    // (hypothetical) bounded 0x15 still resolves NO attach point — node
    // endpoints never anchor at their own box — but the one-anchored walked
    // tier ships a route to the node box's near edge off the exact tunnel end.
    List<int> records(int endpointKind) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // attach (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(endpointKind, 5),
      ...bounds(6, 100, 22, 132), // floored centre (116, 14)
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      0x45, 0xe7, 0x02, 0x08, // [02][right]: straight table
      ...close(),
    ];
    final leaf = dia(records(0x16));
    expect(leaf.wireAttachPoint(5), (x: 116, y: 14));
    expect(leaf.wires.single.routePoints, [(x: 9, y: 14), (x: 116, y: 14)]);
    final node = dia(records(0x15));
    expect(node.wireAttachPoint(5), isNull);
    expect(node.wires.single.routePoints, [(x: 9, y: 14), (x: 100, y: 14)]);
  });

  test('wireAttachPoint: each shift register attaches 4px interior-ward of centre', () {
    // A shift-register terminal on a loop frame, attach rect floored-centre
    // (9,14). The right register's (0x28) connection column sits 4px left, so
    // its attach point is (5,14); the left register's (0x27) sits 4px right,
    // (13,14); any other terminal keeps the plain centre (9,14). Only x moves.
    List<int> records(int terminalKind) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(terminalKind, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // floored centre (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...close(),
    ];
    expect(dia(records(0x28)).wireAttachPoint(3), (x: 5, y: 14)); // right: centre.x - 4
    expect(dia(records(0x27)).wireAttachPoint(3), (x: 13, y: 14)); // left: centre.x + 4
    expect(dia(records(0x22)).wireAttachPoint(3), (x: 9, y: 14)); // non-shift terminal: unchanged
  });

  test('routePoints: a bent walk ships off either shift register at its decoded column', () {
    // One-anchored walk from a shift-register terminal (attach floored-centre
    // (9,14)) into a plain-node box. The far 0x15 endpoint owns its box
    // (40,60)-(60,92); the stored route bends (right then down). Off the RIGHT
    // register the anchor lands on the decoded column x=5; off the LEFT on
    // x=13 — both bent walks ship from their register's connection column.
    List<int> records(int terminalKind) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(terminalKind, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // floored centre (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x15, 5),
      ...bounds(40, 60, 60, 92), // far plain-node box; left edge x=60
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...c5(0xe7, [0x04, 0x08, 0x00, 0x00, 55, 36]), // right then down
      ...close(),
    ];
    // Right register: anchor (5,14), right 55 -> x=60 (far box left edge), down
    // 36 -> y=50 (within the box's 40..60 y-span): a shipped bent walk.
    expect(dia(records(0x28)).wires.single.routePoints, [(x: 5, y: 14), (x: 60, y: 14), (x: 60, y: 50)]);
    // Left register: anchor (13,14); the stored bend column rides the +4.
    expect(dia(records(0x27)).wires.single.routePoints, [(x: 13, y: 14), (x: 68, y: 14), (x: 68, y: 50)]);
  });

  test('routePoints: a 3+-endpoint signal ships nothing even when its table decodes', () {
    final d = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]),
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x03, 0x08, 0x00, 0x14]),
      ...close(),
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
    // FF escape in a length.
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x05, 0x03, 0xff, 0x01, 0x00, 20, 30]))!.segmentLengths, [
      256,
      20,
      30,
    ]);
    // The two-endpoint form (direction code, not 00) is not this grammar.
    expect(decodeWireBranchRoute(u8([0x04, 0x08, 0x00, 0x00, 28, 12])), isNull);
    // A later mode byte outside sign/pop/junction is malformed.
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x09, 0x03, 10, 20, 30])), isNull);
    // Pop balance: a pop with no pending junction direction, and a junction
    // whose pending direction is never consumed.
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x08, 0x03, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x08, 0x05, 10, 20])), isNull);
    // Length-count mismatch.
    expect(decodeWireBranchRoute(u8([0x04, 0x00, 0x08, 0x05, 0x03, 10, 20])), isNull);
    // A zero or out-of-range first mode byte carries no direction bits.
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x00, 0x03, 10, 20])), isNull);
    expect(decodeWireBranchRoute(u8([0x03, 0x00, 0x10, 0x03, 10, 20])), isNull);
    // The junction catalog is exactly 04..07.
    expect(WireRouteJunction.fromCode(0x04), WireRouteJunction.cross);
    expect(WireRouteJunction.fromCode(0x07), WireRouteJunction.upDown);
    expect(WireRouteJunction.fromCode(0x03), isNull);
    expect(WireRouteJunction.fromCode(0x08), isNull);
  });

  test('walkWireBranchRoute: each junction code branches and resumes on its catalog directions', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    // downRight (05): branch down, sign bend, pop resumes right from the dot.
    final t5 = walk([0x05, 0x00, 0x08, 0x05, 0x00, 0x03, 10, 20, 15, 30]);
    expect(t5.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: 20), (x: 25, y: 20)],
      [(x: 10, y: 0), (x: 40, y: 0)],
    ]);
    expect(t5.junctions, [(x: 10, y: 0)]);
    expect(t5.leaves, [(x: 25, y: 20), (x: 40, y: 0)]);
    // upRight (06): branch up, resume right.
    final t6 = walk([0x04, 0x00, 0x08, 0x06, 0x03, 10, 20, 30]);
    expect(t6.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: -20)],
      [(x: 10, y: 0), (x: 40, y: 0)],
    ]);
    // upDown (07): branch up, resume down.
    final t7 = walk([0x04, 0x00, 0x08, 0x07, 0x03, 10, 20, 30]);
    expect(t7.leaves, [(x: 10, y: -20), (x: 10, y: 30)]);
    // cross (04): three outgoing — up, then down, then right (two pops).
    final t4 = walk([0x05, 0x00, 0x08, 0x04, 0x03, 0x03, 10, 20, 30, 40]);
    expect(t4.leaves, [(x: 10, y: -20), (x: 10, y: 30), (x: 50, y: 0)]);
    expect(t4.junctions, [(x: 10, y: 0)]);
  });

  test('walkWireBranchRoute: start masks, blocked-direction substitution, negative bends', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    // A multi-bit first mode forks at the origin: mask 0x0C = {down, right},
    // walked in ascending code order, with the dot on the origin itself.
    final tMask = walk([0x03, 0x00, 0x0c, 0x03, 15, 25]);
    expect(tMask.polylines, [
      [(x: 0, y: 0), (x: 0, y: 15)],
      [(x: 0, y: 0), (x: 25, y: 0)],
    ]);
    expect(tMask.junctions, [(x: 0, y: 0)]);
    // Substitution: entering an upRight junction travelling DOWN blocks its
    // nominal up-branch (it would walk back along the incoming edge), so the
    // branch goes left; the resume right is untouched. The bend after the
    // horizontal branch alternates onto the vertical axis.
    final tSub = walk([0x05, 0x00, 0x04, 0x06, 0x00, 0x03, 10, 20, 15, 30]);
    expect(tSub.polylines, [
      [(x: 0, y: 0), (x: 0, y: 10), (x: -20, y: 10), (x: -20, y: 25)],
      [(x: 0, y: 10), (x: 30, y: 10)],
    ]);
    // A negative bend after a vertical branch runs left.
    final tNeg = walk([0x05, 0x00, 0x08, 0x05, 0x01, 0x03, 10, 20, 15, 30]);
    expect(tNeg.polylines.first.last, (x: -5, y: 20));
  });

  test('walkWireBranchRoute: nested (depth-2) junctions resume LIFO past an exhausted junction', () {
    const start = (x: 0, y: 0);
    // right, then two stacked downRight junctions, then two pops: the first
    // pop resumes the INNER junction (LIFO), the second must skip the now
    // empty inner and resume the OUTER — the stack-exhaustion path.
    final t = walkWireBranchRoute(
      decodeWireBranchRoute(u8([0x06, 0x00, 0x08, 0x05, 0x05, 0x03, 0x03, 10, 20, 15, 30, 40]))!,
      start,
    );
    expect(t.junctions, [(x: 10, y: 0), (x: 10, y: 20)]);
    expect(t.polylines, [
      [(x: 0, y: 0), (x: 10, y: 0), (x: 10, y: 20), (x: 10, y: 35)],
      [(x: 10, y: 20), (x: 40, y: 20)], // inner junction resumes right
      [(x: 10, y: 0), (x: 50, y: 0)], // outer junction resumes right
    ]);
    expect(t.leaves, [(x: 10, y: 35), (x: 40, y: 20), (x: 50, y: 0)]);
  });

  test('walkWireBranchRoute: 3-bit start mask forks three arms; substitution across codes and axes', () {
    const start = (x: 0, y: 0);
    ViWireRouteTree walk(List<int> table) => walkWireBranchRoute(decodeWireBranchRoute(u8(table))!, start);
    // Mask 0x0D = {up, down, right} (ascending code order): first arm up, two
    // pops walk down then right. Three leaves, one origin dot.
    final t3 = walk([0x04, 0x00, 0x0d, 0x03, 0x03, 10, 20, 30]);
    expect(t3.junctions, [(x: 0, y: 0)]);
    expect(t3.leaves, [(x: 0, y: -10), (x: 0, y: 20), (x: 30, y: 0)]);
    // Mask 0x0E = {left, down, right}.
    expect(walk([0x04, 0x00, 0x0e, 0x03, 0x03, 10, 20, 30]).leaves, [(x: -10, y: 0), (x: 0, y: 20), (x: 30, y: 0)]);
    // cross entered travelling UP: reverse is down, so the catalog's DOWN
    // arm substitutes to left; up-branch and right-resume are untouched.
    final tCross = walk([0x05, 0x00, 0x01, 0x04, 0x03, 0x03, 10, 20, 30, 40]);
    expect(tCross.junctions, [(x: 0, y: -10)]);
    expect(tCross.leaves, [(x: 0, y: -30), (x: -30, y: -10), (x: 40, y: -10)]);
    // upDown entered travelling UP: reverse is down, so the DOWN resume
    // substitutes to left — the second arm runs left, not down.
    final tUpDown = walk([0x04, 0x00, 0x01, 0x07, 0x03, 10, 20, 30]);
    expect(tUpDown.leaves, [(x: 0, y: -30), (x: -30, y: -10)]);
  });

  test('routeTree gate: an unanchored origin reverse-solves; a leaf-count mismatch ships nothing', () {
    // Three anchored tunnels (oids 3/5/7) plus a bare 0x15 node (oid 8) that
    // no terminal claims — it resolves no attach point.
    List<int> records(List<int> firstRef, List<int> table) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]),
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a),
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 40, 0, 25, 0, 49, 0, 34]),
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 6, tag: 0x1a),
      ...hx('14 19 01 fd 0007'),
      ...c5(0x29, [0, 10, 0, 50, 0, 19, 0, 59]),
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...open(0x15, 8, tag: 0x1a), // bare node, no terminal — no attach point
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...firstRef,
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, table),
      ...close(),
    ];
    // A valid 3-endpoint tree whose first endpoint (the bare node) resolves
    // no attach point: the REVERSE-SOLVED tier ships it — exactly one
    // translation closes both anchored tunnels ((29,44) via the branch leaf,
    // (54,14) via the trailing run) and lands the implied origin (9,14)
    // inside the head's owner box (the alternative seed translation
    // (-16,44) falls outside it). Fidelity is walked: the head is derived,
    // not independently confirmed.
    final noOrigin = dia(records(hx('14 19 01 fd 0008'), [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25])).wires.single;
    expect(noOrigin.branchRoute, isNotNull);
    expect(noOrigin.routeTree, isNotNull);
    expect(noOrigin.routeTreeFidelity, WireRouteFidelity.walked);
    expect(noOrigin.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(noOrigin.routeTree!.junctions, [(x: 29, y: 14)]);
    // A table with too few leaves for the endpoint count (one straight run,
    // no pops -> a single leaf vs three endpoints): the gate rejects it.
    final fewLeaves = dia(records(hx('14 19 01 fd 0003'), [0x03, 0x00, 0x08, 0x00, 20, 30])).wires.single;
    expect(fewLeaves.branchRoute, isNotNull);
    expect(fewLeaves.routeTree, isNull);
  });

  test('routeTree reverse-solve gate: an ambiguous translation ships nothing', () {
    // One anchored tunnel (oid 3) and TWO bare 0x15 nodes (oids 5 and 7 have
    // no terminal claim): with a single resolved endpoint, BOTH leaves of the
    // 08 05 03 tree yield a translation that closes it — (40,14) via the
    // branch leaf and (15,44) via the trailing run — and both land inside
    // the head's owner box, so the solve is ambiguous and withheld.
    final records = [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 40, 0, 56, 0, 49, 0, 65]), // attach (60, 44)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25]),
      ...close(),
    ];
    final wire = dia(records).wires.single;
    expect(wire.branchRoute, isNotNull);
    expect(wire.routeTree, isNull);
  });

  test('routeTree: a fully-anchored branching signal ships exactly-closing trees only', () {
    // Three structure tunnels; the stored tree walks right 20 from the first
    // tunnel's attach centre (9,14), forks at (29,14) down 30 onto the second
    // tunnel (29,44), and resumes right 25 onto the third (54,14).
    List<int> records({required int thirdLeft}) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // attach (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a),
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 40, 0, 25, 0, 49, 0, 34]), // attach (29, 44)
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 6, tag: 0x1a),
      ...hx('14 19 01 fd 0007'),
      ...c5(0x29, [0, 10, 0, thirdLeft, 0, 19, 0, thirdLeft + 9]), // attach (thirdLeft+4, 14)
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25]),
      ...close(),
    ];
    final good = dia(records(thirdLeft: 50)).wires.single;
    expect(good.route, isNull, reason: 'the extended form is not the two-endpoint grammar');
    expect(good.branchRoute, isNotNull);
    expect(good.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(good.routeTree!.junctions, [(x: 29, y: 14)]);
    // A leaf landing 1 px off its attach point ships nothing — never
    // force-closed; the decoded program still ships.
    final miss = dia(records(thirdLeft: 51)).wires.single;
    expect(miss.branchRoute, isNotNull);
    expect(miss.routeTree, isNull);
  });

  test('walkOneAnchoredRoute: forward, reverse-straight, and underdetermined/inconsistent cases', () {
    ViWireRoute r(int n, WireRouteDirection dir, List<int> signs, List<int> lens) =>
        ViWireRoute(pointCount: n, direction: dir, segmentLengths: lens, jointSigns: signs);
    // Far node box below-right of the walk; a vertical closing run into its
    // top edge, a horizontal one into a side edge.
    const box = HeapRect(top: 40, left: 40, bottom: 60, right: 60);

    // Forward, one bend: anchor (10, 20) walks right 30, then the implied
    // closing run drops onto the box's top edge (y = 40) at the bend column.
    final oneBend = walkOneAnchoredRoute(
      r(3, WireRouteDirection.right, [1], [30]),
      anchor: (x: 10, y: 20),
      anchoredIndex: 0,
      farBox: box,
    );
    expect(oneBend?.points, [(x: 10, y: 20), (x: 40, y: 20), (x: 40, y: 40)]);
    // Reaching the box EDGE (not entering it) reports no into-node step.
    expect(oneBend?.closingStep, isNull);
    // Forward, straight (no bends): the whole run is the closing run, ending
    // on the box's near (left) edge.
    expect(
      walkOneAnchoredRoute(
        r(2, WireRouteDirection.right, const [], const []),
        anchor: (x: 5, y: 50),
        anchoredIndex: 0,
        farBox: box,
      )?.points,
      [(x: 5, y: 50), (x: 40, y: 50)],
    );
    // Reverse, straight: the anchor is the SECOND endpoint (100, 50); the
    // first endpoint rides the box's far (right) edge (x = 59), storage order.
    expect(
      walkOneAnchoredRoute(
        r(2, WireRouteDirection.right, const [], const []),
        anchor: (x: 100, y: 50),
        anchoredIndex: 1,
        farBox: box,
      )?.points,
      [(x: 59, y: 50), (x: 100, y: 50)],
    );
    // Reverse with an odd point count leaves the far endpoint's along-run
    // position unpinned — null (the departing and closing axes differ).
    expect(
      walkOneAnchoredRoute(
        r(3, WireRouteDirection.right, [1], [30]),
        anchor: (x: 100, y: 50),
        anchoredIndex: 1,
        farBox: box,
      ),
      isNull,
    );
    // A forward closing run that would double back against the stored sign
    // (box placed the wrong way) ships null.
    expect(
      walkOneAnchoredRoute(
        r(3, WireRouteDirection.right, [1], [30]),
        anchor: (x: 10, y: 80),
        anchoredIndex: 0,
        farBox: box, // box.top = 40 is ABOVE the bend at y = 80; +sign wants down
      ),
      isNull,
    );
    // Cross-axis containment: a horizontal closing run whose terminus ROW falls
    // outside the box's vertical span points into empty space beside the node —
    // null. (Bend at y = 200, box spans y 40..60.)
    expect(
      walkOneAnchoredRoute(
        r(3, WireRouteDirection.down, [1], [160]),
        anchor: (x: 30, y: 40),
        anchoredIndex: 0,
        farBox: box, // walks down 160 to y = 200, then a horizontal run — y ∉ [40,60]
      ),
      isNull,
    );
    // Reverse straight with the box on the WRONG side (the departing run cannot
    // reach it in the stored direction) ships null.
    expect(
      walkOneAnchoredRoute(
        r(2, WireRouteDirection.right, const [], const []),
        anchor: (x: 30, y: 50),
        anchoredIndex: 1,
        farBox: const HeapRect(
          top: 40,
          left: 100,
          bottom: 60,
          right: 120,
        ), // box is RIGHT of the anchor; dir=right departs right
      ),
      isNull,
    );
    // Zero-length closing run: the walk's last bend already sits on the box
    // edge, so no duplicate terminal vertex is appended (pointCount - 1 points).
    final zeroClose = walkOneAnchoredRoute(
      r(3, WireRouteDirection.right, [1], [30]),
      anchor: (x: 10, y: 40),
      anchoredIndex: 0,
      farBox: box, // bend lands at (40, 40) == box top-left; closing run length 0
    );
    expect(zeroClose?.points, [(x: 10, y: 40), (x: 40, y: 40)]);
    // A zero-length close reaches the box EDGE, not the interior — NO into-node
    // step. This locks the boundary against the into-node case below (both emit
    // pointCount-1 points, but only an interior entry carries a step).
    expect(zeroClose?.closingStep, isNull);
    // Into-node close (horizontal, +x): the last decoded bend lands in the box
    // INTERIOR (x = 45, past the left edge 40), so the implied run enters the
    // node. The polyline stops at the bend and the +x step is reported — no
    // fabricated terminus at the node's undecoded input-pin depth.
    final intoH = walkOneAnchoredRoute(
      r(4, WireRouteDirection.right, [1], [35, 5]),
      anchor: (x: 10, y: 50),
      anchoredIndex: 0,
      farBox: box, // walks right 35 to x=45 (inside), down 5 to (45,55)
    );
    expect(intoH?.points, [(x: 10, y: 50), (x: 45, y: 50), (x: 45, y: 55)]);
    expect(intoH?.closingStep, (dx: 1, dy: 0));
    // Into-node close (vertical, +y): last bend inside the box, run enters down.
    final intoV = walkOneAnchoredRoute(
      r(4, WireRouteDirection.down, [1], [15, 5]),
      anchor: (x: 50, y: 35),
      anchoredIndex: 0,
      farBox: box, // down 15 to y=50 (inside), right 5 to (55,50)
    );
    expect(intoV?.points, [(x: 50, y: 35), (x: 50, y: 50), (x: 55, y: 50)]);
    expect(intoV?.closingStep, (dx: 0, dy: 1));
    // Into-node close (horizontal, −x): approaches from the right, the last bend
    // lands inside, the run steps deeper LEFT.
    final intoLeft = walkOneAnchoredRoute(
      r(4, WireRouteDirection.left, [-1], [35, 5]),
      anchor: (x: 90, y: 50),
      anchoredIndex: 0,
      farBox: box, // left 35 to x=55 (inside), up 5 to (55,45)
    );
    expect(intoLeft?.points, [(x: 90, y: 50), (x: 55, y: 50), (x: 55, y: 45)]);
    expect(intoLeft?.closingStep, (dx: -1, dy: 0));
    // Into-node close (vertical, −y): the run steps deeper UP.
    final intoUp = walkOneAnchoredRoute(
      r(4, WireRouteDirection.up, [-1], [15, 5]),
      anchor: (x: 50, y: 70),
      anchoredIndex: 0,
      farBox: box, // up 15 to y=55 (inside), left 5 to (45,55)
    );
    expect(intoUp?.points, [(x: 50, y: 70), (x: 50, y: 55), (x: 45, y: 55)]);
    expect(intoUp?.closingStep, (dx: 0, dy: -1));
    // Into-node reject (horizontal): a bend BEYOND the far edge (x = 70 > box)
    // has no node to enter — null.
    expect(
      walkOneAnchoredRoute(
        r(4, WireRouteDirection.right, [1], [60, 5]),
        anchor: (x: 10, y: 50),
        anchoredIndex: 0,
        farBox: box,
      ),
      isNull,
    );
    // Into-node reject (vertical): the last bend's ROW falls beyond the far edge
    // (y = 70 ≥ bottom 60) — no interior to enter — null.
    expect(
      walkOneAnchoredRoute(
        r(4, WireRouteDirection.down, [1], [60, 5]),
        anchor: (x: 50, y: 10),
        anchoredIndex: 0,
        farBox: box,
      ),
      isNull,
    );
    // Into-node reject (off-by-one): a bend AT the EXCLUSIVE right edge (x = 60,
    // one past the last interior column 59) is outside the interior — null.
    expect(
      walkOneAnchoredRoute(
        r(4, WireRouteDirection.right, [1], [50, 5]),
        anchor: (x: 10, y: 50),
        anchoredIndex: 0,
        farBox: box, // right 50 to x=60 == box.right (exclusive)
      ),
      isNull,
    );
    // Into-node reject (step exits): the bend sits at the LAST interior column
    // (x = 59) but the +x run would step to 60, out of the box — the run must
    // head DEEPER in, so this is rejected.
    expect(
      walkOneAnchoredRoute(
        r(4, WireRouteDirection.right, [1], [49, 5]),
        anchor: (x: 10, y: 50),
        anchoredIndex: 0,
        farBox: box,
      ),
      isNull,
    );
    // Degenerate reject: a BENDLESS route (2 points, no stored segment) whose
    // anchor already sits inside the box yields a 1-point local frame — no
    // drawable segment — so the into-node branch withholds it rather than ship
    // a zero-segment polyline the census would count but nothing could draw.
    expect(
      walkOneAnchoredRoute(
        r(2, WireRouteDirection.right, const [], const []),
        anchor: (x: 45, y: 50),
        anchoredIndex: 0,
        farBox: box,
      ),
      isNull,
    );
  });

  test('routePoints walked tier: one exact anchor ships the walk; the far plain node rides its box', () {
    // An anchored structure tunnel (attach 9,14) and a bounded primitive node
    // whose plain 0x15 endpoint resolves no attach point. [refs] orders the
    // signal's two endpoints; [table] is its stored route.
    // [nodeBounds] positions the far plain node's box so its edge actually
    // contains the connection point (the cross-axis containment gate rejects a
    // terminus that lands beside the box).
    List<int> records(String a, String b, List<int> table, List<int> nodeBounds) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x22, 2, tag: 0x1a), // tunnel terminal, structure-framed -> exact anchor
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // attach (9, 14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x2f, 6, tag: 0x1a), // a bounded primitive node
      ...bounds(nodeBounds[0], nodeBounds[1], nodeBounds[2], nodeBounds[3]),
      ...open(0x15, 7, tag: 0x1b), // plain node endpoint (no terminal, no constant)
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 000$a'),
      ...hx('14 19 01 fd 000$b'),
      ...c5(0xe7, table),
      ...close(),
    ];
    // Forward: anchor is endpoint 0 (the tunnel). Walk right 30 from (9,14) to
    // the bend (39,14), then the closing run drops onto the node's top edge
    // (y = 40); x = 39 lies within the box span [30, 90].
    final fwdDia = dia(records('3', '7', [0x03, 0x08, 0x00, 30], [40, 30, 60, 90]));
    expect(fwdDia.wireAttachPoint(3), (x: 9, y: 14));
    expect(fwdDia.wireAttachPoint(7), isNull);
    expect(fwdDia.wires.single.routePoints, [(x: 9, y: 14), (x: 39, y: 14), (x: 39, y: 40)]);
    expect(fwdDia.wires.single.routePointsFidelity, WireRouteFidelity.walked);
    // Reverse straight: anchor is endpoint 1 (the tunnel) at row 14; the plain
    // node (endpoint 0) rides the box edge the wire departs. dir=left leaves
    // the node's LEFT edge (x = 40); the box spans y [5, 25] around row 14.
    // Storage order: plain, then anchor.
    final rev = dia(records('7', '3', [0x02, 0x02], [5, 40, 25, 90])).wires.single;
    expect(rev.routePoints, [(x: 40, y: 14), (x: 9, y: 14)]);
    // Reverse with an ODD stored-bend count: the departing and closing axes
    // differ, so the reverse geometry is underdetermined and ships nothing.
    final revBent = dia(records('7', '3', [0x03, 0x02, 0x00, 30], [5, 40, 25, 90])).wires.single;
    expect(revBent.routePoints, isNull);
    // Reverse with an EVEN stored-bend count ships, the head pinned at the
    // departure edge and the undecoded terminal depth marked INTERIOR-ward
    // on routeHeadSlack: dir=left departs the node's LEFT edge (x = 40), so
    // the marked slide direction is +x, into the box.
    final revSlack = dia(
      records('7', '3', [0x04, 0x02, 0x00, 0x01, 10, 6], [5, 40, 25, 90]),
    ).wires.single;
    expect(revSlack.routePoints, [
      (x: 40, y: 8),
      (x: 30, y: 8),
      (x: 30, y: 14),
      (x: 9, y: 14),
    ]);
    expect(revSlack.routePointsFidelity, WireRouteFidelity.walked);
    expect(revSlack.routeHeadSlack, (dx: 1, dy: 0));
    // A zero-length closing run still carries the anchor as an explicit
    // trailing point on a slack ship, so the consumer's
    // translate-all-but-the-anchor resolution needs no special casing.
    final revSlackZero = dia(
      records('7', '3', [0x04, 0x02, 0x00, 0x01, 31, 6], [5, 40, 25, 90]),
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
    // Both endpoints are bare plain nodes: neither resolves an attach point.
    List<int> bothBare(List<int> table) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x2f, 6, tag: 0x1a),
      ...bounds(40, 40, 60, 90),
      ...open(0x15, 7, tag: 0x1b),
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, table),
      ...close(),
    ];
    expect(dia(bothBare([0x03, 0x08, 0x00, 30])).wires.single.routePoints, isNull);

    // Endpoint 3 wraps a drawn CONSTANT (a `0x13` DCO with a bounded value
    // shell): it resolves an attach point (the shell centre) but it is COARSE —
    // the wire leaves a constant at its drawn edge, not the box centre — so
    // [_exactAttach] rejects it and the walked tier withholds the route, even
    // though the far end is a plain node.
    final constAnchor = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x15, 3, tag: 0x1a),
      ...open(0x13, 10, tag: 0x1b), // constant DCO
      ...open(0x2f, 11, tag: 0x1c),
      ...bounds(10, 10, 26, 42), // bounded value shell -> shell centre (26, 18)
      ...close(0x1c),
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x2f, 6, tag: 0x1a),
      ...bounds(40, 40, 60, 90),
      ...open(0x15, 7, tag: 0x1b),
      ...close(0x1b),
      ...close(0x1a),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x02, 0x08]),
      ...close(),
    ]);
    expect(constAnchor.wireAttachPoint(3), isNotNull, reason: 'the constant shell resolves an attach point');
    expect(constAnchor.wires.single.routePoints, isNull, reason: 'but a coarse constant-shell anchor is withheld');
  });

  test('routeTree walked tier: origin-anchored, contradiction-free trees ship; a missed resolved leaf does not', () {
    // Origin tunnel (attach 9,14) forks: right 20 to (29,14), branch down 30,
    // resume right 25. Leaves at (29,44) and (54,14). [secondLeaf] is either a
    // bare plain node (rides the walk) or an anchored tunnel that may or may
    // not close.
    List<int> records({required bool bareSecond, int thirdLeft = 50}) => [
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // origin attach (9,14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      // Second leaf: a bare plain node (oid 5) OR an anchored tunnel.
      if (bareSecond) ...[
        ...open(0x15, 5, tag: 0x1a),
        ...close(0x1a),
      ] else ...[
        ...open(0x22, 4, tag: 0x1a),
        ...hx('14 19 01 fd 0005'),
        ...c5(0x29, [0, 40, 0, 25, 0, 49, 0, 34]), // attach (29,44)
        ...close(0x1a),
        ...open(0x15, 5, tag: 0x1a),
        ...close(0x1a),
      ],
      ...open(0x22, 6, tag: 0x1a),
      ...hx('14 19 01 fd 0007'),
      ...c5(0x29, [0, 10, 0, thirdLeft, 0, 19, 0, thirdLeft + 9]), // attach (thirdLeft+4, 14)
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25]),
      ...close(),
    ];
    // Origin anchored, second leaf a plain node (rides the walk), third leaf
    // closes exactly: the contradiction-free walked tree ships as the walked
    // tier.
    final walked = dia(records(bareSecond: true)).wires.single;
    expect(walked.routeTree!.polylines, [
      [(x: 9, y: 14), (x: 29, y: 14), (x: 29, y: 44)],
      [(x: 29, y: 14), (x: 54, y: 14)],
    ]);
    expect(walked.routeTree!.junctions, [(x: 29, y: 14)]);
    expect(walked.routeTreeFidelity, WireRouteFidelity.walked);
    // All three anchored and closing = the proven closed tier.
    final closed = dia(records(bareSecond: false)).wires.single;
    expect(closed.routeTree, isNotNull);
    expect(closed.routeTreeFidelity, WireRouteFidelity.closed);
    // The third leaf, now anchored, lands 1 px off its attach point: a
    // resolved endpoint the walk MISSES is a contradiction — ships nothing.
    final contradiction = dia(records(bareSecond: true, thirdLeft: 51)).wires.single;
    expect(contradiction.routeTree, isNull);
  });

  test('routeTree walked tier: two resolved endpoints cannot share one walked leaf', () {
    // Origin (9,14) forks to leaves (29,44) and (54,14). BOTH non-origin
    // endpoints are anchored tunnels whose attach point is (54,14): they would
    // both have to claim the single (54,14) leaf — a collision the greedy
    // multiset match rejects, so nothing ships (never double-counted).
    final d = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 200, 200),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // origin (9,14)
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 4, tag: 0x1a),
      ...hx('14 19 01 fd 0005'),
      ...c5(0x29, [0, 10, 0, 50, 0, 19, 0, 59]), // (54,14)
      ...close(0x1a),
      ...open(0x15, 5, tag: 0x1a),
      ...close(0x1a),
      ...open(0x22, 6, tag: 0x1a),
      ...hx('14 19 01 fd 0007'),
      ...c5(0x29, [0, 10, 0, 50, 0, 19, 0, 59]), // (54,14) — same as leaf 5
      ...close(0x1a),
      ...open(0x15, 7, tag: 0x1a),
      ...close(0x1a),
      ...close(),
      ...open(0x17, 9),
      ...hx('14 19 01 fd 0003'),
      ...hx('14 19 01 fd 0005'),
      ...hx('14 19 01 fd 0007'),
      ...c5(0xe7, [0x04, 0x00, 0x08, 0x05, 0x03, 20, 30, 25]),
      ...close(),
    ]);
    expect(d.wireAttachPoint(5), (x: 54, y: 14));
    expect(d.wireAttachPoint(7), (x: 54, y: 14));
    expect(d.wires.single.routeTree, isNull);
  });

  test('endpointTerminalBounds: attach rect = termBounds + enclosing frame origin', () {
    final records = [
      ...open(0x20, 1), // loop structure at (100, 50)
      ...bounds(100, 50, 200, 150),
      ...open(0x22, 2, tag: 0x1a), // tunnel terminal: childRefs the endpoint, carries termBounds
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 10, 0, 5, 0, 19, 0, 14]), // t:10 l:5 b:19 r:14
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
    // The version gate: < 8.6 heaps store a different (absolute) space, so
    // the composed rect would be wrong — null, never fabricated.
    expect(dia(records, version: '8.5').endpointTerminalBounds(3), isNull);
    expect(dia(records, version: '8.6').endpointTerminalBounds(3), isNotNull);
    // A ViWire constructed without an attach list defaults to aligned nulls.
    expect(ViWire(signalOid: 9, endpointOids: [3, 4], endpointAnchors: [null, null]).endpointAttachRects, [
      null,
      null,
    ]);
  });

  test('endpointTerminal: an endpoint two terminals claim resolves to nothing', () {
    final d = dia([
      ...open(0x20, 1),
      ...bounds(0, 0, 100, 100),
      ...open(0x22, 2, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 0, 0, 0, 0, 9, 0, 9]),
      ...close(0x1a),
      ...open(0x22, 5, tag: 0x1a),
      ...hx('14 19 01 fd 0003'),
      ...c5(0x29, [0, 1, 0, 1, 0, 9, 0, 9]),
      ...close(0x1a),
      ...open(0x15, 3, tag: 0x1a),
      ...close(0x1a),
      ...close(),
    ]);
    expect(d.endpointTerminal(3), isNull, reason: 'ambiguous claims are dropped, never guessed (corpus: 0)');
    expect(d.endpointTerminalBounds(3), isNull);
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

  test('an owned label composes against its owner even when the owner bounds record trails it', () {
    // A case structure whose label child (stored at (-17,0), directly above
    // the case) serialises BEFORE the structure's own bounds record — the
    // shape that mis-anchored crc8's "Reflect Input?" to the enclosing loop.
    final d = dia([
      ...open(0x20, 1),
      ...bounds(100, 200, 400, 700),
      ...open(0x2c, 2, tag: 0x1a),
      ...open(0xa, 3, tag: 0x1b),
      ...bounds(-17, 0, 0, 75),
      ...caption('Reflect Input?'),
      ...close(0x1b),
      ...bounds(50, 40, 120, 130), // the owner's bounds arrive after the label
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
    // The icon-asset naming contract: prim<id>_<slug>.png.
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
        0x6c, 0x36, 0x153, 0x6a, 0xbd, 0x114, 0xb6, 0xb9, 0x48, 0xeb, 0x103, 0x14a, 0x124, //
        0x150, 0x14f, 0x152,
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
/// DTHP-declared base, the no-base decline, and the dcoRef inheritance.
void resolveTypesTests() {
  ViType type(int i, ViDataType k, [String? name]) => ViType(index: i, code: 0, kind: k, name: name);
  // Pool: [0]=void, [1]=string "data in", [2]=boolean, [3]=i32.
  final pool = [
    type(0, ViDataType.voidType),
    type(1, ViDataType.string, 'data in'),
    type(2, ViDataType.boolean),
    type(3, ViDataType.i32),
  ];
  // A DTHP declaring 4 heap types starting at the 1-based top-level index 3
  // puts the heap's index space at table entries 2..5, i.e. base +1.
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
    final strConst = obj(1, 0x51, tdi: 1); // table[3-1] = 1 → string ✓
    final boolConst = obj(2, 0x4f, tdi: 2); // table[4-1] = 2 → boolean ✓
    final loopCount = obj(3, 0x24, tdi: 3); // table[5-1] = 3 → i32 ✓
    final dco = obj(10, 0x12, tdi: 4); // table[6-1] = 1 → string "data in"
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
    // The 0x16 inherited kind + name through its dcoRef.
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
