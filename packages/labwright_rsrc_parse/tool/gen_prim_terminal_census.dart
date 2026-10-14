import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import '../../../tool/corpus.dart';

/// Run: `dart run tool/gen_prim_terminal_census.dart`; writes `lib/src/diagram/prim_terminal_census.dart`.
void main() {
  final root = corpusVi;
  final xObs = <(int, int, int, int), Map<int, int>>{};
  final yObs = <(int, int, int, int), Map<int, int>>{};
  var files = 0, slackWires = 0;
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    final path = f.path;
    final isVi = path.endsWith('.vi') || path.endsWith('.vim') || path.endsWith('.vit') || path.endsWith('.ctl');
    final isPng = path.endsWith('.png');
    if (!isVi && !isPng) continue;
    Uint8List bytes;
    try {
      bytes = f.readAsBytesSync();
      if (isPng) {
        final embedded = extractSnippetVi(bytes);
        if (embedded == null) continue;
        bytes = embedded;
      }
    } catch (_) {
      continue;
    }
    ViModel model;
    try {
      model = buildViModel(bytes);
    } catch (_) {
      continue;
    }
    files++;
    for (final diagram in model.blockDiagrams) {
      for (final wire in diagram.wires) {
        _recordLeaves(diagram, wire, xObs, yObs);
        final slack = wire.routeHeadSlack;
        final points = wire.routePoints;
        if (slack == null || points == null || points.isEmpty) continue;
        ViHeapObject? dco;
        for (final oid in wire.endpointOids) {
          final o = diagram.byId[oid];
          if (o != null && o.kind == kNodeEndpointDcoKind && o.absBounds == null) {
            dco = o;
            break;
          }
        }
        if (dco == null) continue;
        final node = diagram.byId[dco.parentOid ?? -1];
        final box = node?.absBounds;
        if (node == null || box == null || box.width <= 0 || box.height <= 0) {
          continue;
        }
        final dcos = [
          for (final c in diagram.children(node.oid))
            if (c.kind == kNodeEndpointDcoKind) c,
        ];
        final termIdx = dcos.indexWhere((c) => c.oid == dco!.oid);
        if (termIdx < 0) continue;
        final key = (
          node.primResId ?? -node.kind,
          termIdx,
          box.width,
          box.height,
        );
        final head = points.first;
        slackWires++;
        if (slack.dx != 0) {
          (yObs[key] ??= {}).update(
            head.y - box.top,
            (c) => c + 1,
            ifAbsent: () => 1,
          );
        } else {
          (xObs[key] ??= {}).update(
            head.x - box.left,
            (c) => c + 1,
            ifAbsent: () => 1,
          );
        }
      }
    }
  }
  stderr.writeln(
    'files=$files slackWires=$slackWires keys=${{...xObs.keys, ...yObs.keys}.length}',
  );
  _writeCensus(xObs, yObs);
}

/// Where each leaf of a walked branch route lands on a primitive node's terminal: the
/// route's own lengths place it, so both axes are exact.
void _recordLeaves(
  ViDiagram diagram,
  ViWire wire,
  Map<(int, int, int, int), Map<int, int>> xObs,
  Map<(int, int, int, int), Map<int, int>> yObs,
) {
  if (wire.routeTreeFidelity != WireRouteFidelity.walked) return;
  final tree = wire.routeTree;
  if (tree == null || tree.leaves.length != wire.endpointOids.length - 1) return;
  final sinks = <(ViHeapObject node, HeapRect box, int termIdx)>[];
  for (var i = 1; i < wire.endpointOids.length; i++) {
    final dco = diagram.byId[wire.endpointOids[i]];
    if (dco == null || dco.kind != kNodeEndpointDcoKind || dco.absBounds != null) continue;
    final node = diagram.byId[dco.parentOid ?? -1];
    final box = node?.absBounds;
    if (node == null || box == null || box.width <= 0 || box.height <= 0) continue;
    final dcos = [
      for (final c in diagram.children(node.oid))
        if (c.kind == kNodeEndpointDcoKind) c,
    ];
    final termIdx = dcos.indexWhere((c) => c.oid == dco.oid);
    if (termIdx >= 0) sinks.add((node, box, termIdx));
  }
  final head = diagram.byId[wire.endpointOids.first];
  final headNode = head == null || head.kind != kNodeEndpointDcoKind || head.absBounds != null
      ? null
      : diagram.byId[head.parentOid ?? -1];
  final headBox = headNode?.absBounds;
  if (headNode != null && headBox != null && headBox.width > 0 && headBox.height > 0) {
    final dcos = [
      for (final c in diagram.children(headNode.oid))
        if (c.kind == kNodeEndpointDcoKind) c,
    ];
    final termIdx = dcos.indexWhere((c) => c.oid == head!.oid);
    final origin = tree.polylines.first.first;
    if (termIdx >= 0 &&
        origin.x >= headBox.left &&
        origin.x <= headBox.right &&
        origin.y >= headBox.top &&
        origin.y <= headBox.bottom) {
      final key = (headNode.primResId ?? -headNode.kind, termIdx, headBox.width, headBox.height);
      (xObs[key] ??= {}).update(origin.x - headBox.left, (c) => c + 1, ifAbsent: () => 1);
      (yObs[key] ??= {}).update(origin.y - headBox.top, (c) => c + 1, ifAbsent: () => 1);
    }
  }
  for (final leaf in tree.leaves) {
    final inside = [
      for (final sink in sinks)
        if (leaf.x >= sink.$2.left && leaf.x <= sink.$2.right && leaf.y >= sink.$2.top && leaf.y <= sink.$2.bottom)
          sink,
    ];
    if (inside.length != 1) continue;
    final (node, box, termIdx) = inside.single;
    final key = (node.primResId ?? -node.kind, termIdx, box.width, box.height);
    (xObs[key] ??= {}).update(leaf.x - box.left, (c) => c + 1, ifAbsent: () => 1);
    (yObs[key] ??= {}).update(leaf.y - box.top, (c) => c + 1, ifAbsent: () => 1);
  }
}

void _writeCensus(Map<(int, int, int, int), Map<int, int>> xObs, Map<(int, int, int, int), Map<int, int>> yObs) {
  final keys = {...xObs.keys, ...yObs.keys}.toList()
    ..sort((a, b) {
      var c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      c = a.$2.compareTo(b.$2);
      if (c != 0) return c;
      c = a.$3.compareTo(b.$3);
      return c != 0 ? c : a.$4.compareTo(b.$4);
    });
  final out = StringBuffer('''
// GENERATED by tool/gen_prim_terminal_census.dart; do not hand-edit.

/// Wire-head attach offsets measured across the corpus, keyed by
/// `(prim icon key, terminal index, node width, node height)`; an axis is null when the
/// corpus never showed a wire leaving the terminal along it or showed more than one value.
const Map<(int, int, int, int), ({int? dx, int? dy})> kBdPrimTerminalCensus = {
''');
  var shipped = 0, axisConflicts = 0;
  for (final key in keys) {
    int? unanimous(Map<int, int>? obs) {
      if (obs == null || obs.isEmpty) return null;
      if (obs.length > 1) {
        axisConflicts++;
        return null;
      }
      return obs.keys.single;
    }

    final xs = xObs[key], ys = yObs[key];
    final dx = unanimous(xs);
    final dy = unanimous(ys);
    if (dx == null && dy == null) continue;
    shipped++;
    final xCount = dx == null ? 0 : xs!.values.single;
    final yCount = dy == null ? 0 : ys!.values.single;
    out.writeln(
      '  (${key.$1}, ${key.$2}, ${key.$3}, ${key.$4}): '
      '(dx: $dx, dy: $dy), // x$xCount y$yCount',
    );
  }
  out.writeln('};');
  stderr.writeln('entries=$shipped axisConflictsDropped=$axisConflicts');
  final target = File('${File.fromUri(Platform.script).parent.parent.path}/lib/src/diagram/prim_terminal_census.dart');
  target.writeAsStringSync(out.toString());
  stderr.writeln('wrote ${target.path}');
}
