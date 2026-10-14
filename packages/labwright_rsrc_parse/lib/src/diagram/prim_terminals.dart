/// Where a wire attaches to a primitive node's terminal: the corpus census
/// ([kBdPrimTerminalCensus]) completed by offsets measured against LabVIEW's own renders.
library;

import 'bd_semantics.dart';
import 'diagram.dart';
import 'objects.dart';
import 'prim_terminal_census.dart';

/// Offsets measured from reference renders, keyed like [kBdPrimTerminalCensus]; they fill
/// axes the census leaves null.
const Map<(int, int, int, int), ({int? dx, int? dy})> kBdPrimTerminalMeasured = {
  (1053, 2, 32, 32): (dx: 11, dy: 11),
  (1809, 1, 32, 32): (dx: 8, dy: 15),
  (1904, 1, 32, 32): (dx: null, dy: 16),
  (1050, 0, 32, 32): (dx: 21, dy: 16),
  (1050, 1, 32, 32): (dx: null, dy: 21),
  (1051, 2, 32, 32): (dx: 11, dy: 11),
  (1052, 1, 32, 32): (dx: null, dy: 21),
  (1052, 2, 32, 32): (dx: null, dy: 11),
  (1056, 3, 32, 32): (dx: 10, dy: 10),
  (1063, 0, 32, 32): (dx: 22, dy: 16),
  (1081, 0, 32, 32): (dx: null, dy: 16),
  (1070, 0, 32, 32): (dx: null, dy: 15),
  (1082, 0, 32, 32): (dx: 22, dy: 16),
  (-0x44, 1, 32, 27): (dx: 24, dy: 22),
  (1142, 0, 32, 32): (dx: 22, dy: 16),
  (1143, 0, 32, 32): (dx: null, dy: 16),
  (1155, 1, 32, 32): (dx: 10, dy: 16),
  (1156, 1, 32, 32): (dx: 10, dy: 16),
  (1166, 2, 32, 32): (dx: 26, dy: 16),
  (1171, 0, 32, 32): (dx: 20, dy: 16),
  (1502, 0, 32, 32): (dx: 24, dy: 15),
  (1814, 0, 32, 32): (dx: null, dy: 16),
  (1815, 0, 32, 32): (dx: null, dy: 16),
  (1900, 0, 32, 32): (dx: 24, dy: 16),
  (1900, 1, 32, 32): (dx: null, dy: 16),
  (1908, 0, 32, 32): (dx: 24, dy: 24),
  (8083, 3, 32, 32): (dx: 28, dy: 4),
};

/// The attach point of the wire head at [endpointOid] on its primitive node, per axis, or
/// null when the endpoint is not a node terminal or no offset is known for the node's icon.
({int? x, int? y})? bdPrimTerminalOf(ViDiagram diagram, int endpointOid) {
  final head = diagram.byId[endpointOid];
  final parentOid = head?.parentOid;
  if (head == null || head.kind != kNodeEndpointDcoKind || parentOid == null) return null;
  final parent = diagram.byId[parentOid];
  final box = parent?.absBounds;
  if (parent == null || box == null) return null;
  final key = primIconKeyOf(parent);
  if (key == null) return null;
  var termIdx = -1;
  var at = 0;
  for (final c in diagram.children(parentOid)) {
    if (c.kind != kNodeEndpointDcoKind) continue;
    if (c.oid == head.oid) {
      termIdx = at;
      break;
    }
    at++;
  }
  if (termIdx < 0) return null;
  final offset = bdPrimTerminalOffset(key, termIdx, box.right - box.left, box.bottom - box.top);
  if (offset == null) return null;
  return (
    x: offset.dx == null ? null : box.left + offset.dx!,
    y: offset.dy == null ? null : box.top + offset.dy!,
  );
}

/// The measured attach offset of terminal [termIdx] on a node of icon [key] drawn [width]
/// by [height], per axis; null when nothing was measured for it.
({int? dx, int? dy})? bdPrimTerminalOffset(int key, int termIdx, int width, int height) {
  final sizedKey = (key, termIdx, width, height);
  return kBdPrimTerminalMeasured[sizedKey] ?? kBdPrimTerminalCensus[sizedKey];
}
