import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Fourth wire hunt: degenerate (line-like) rect records chain end-to-start —
/// LabVIEW wires are Manhattan-routed, so h/v segments chained at their
/// endpoints is exactly a wire polyline. WHICH object class owns them?
///
/// For each BD object: collect its records' rects, count degenerate ones and
/// end-to-start chain links, and report per class code: objects, chains,
/// segments. If one class dominates, that's the wire object.
String _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/$pkgRel/sources.json').existsSync()) return '${dir.path}/$pkgRel';
    if (File('${dir.path}/corpus/sources.json').existsSync()) return '${dir.path}/corpus';
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return 'corpus';
}

bool _sharesEndpoint(HeapRect a, HeapRect b) {
  final aPts = [(a.top, a.left), (a.bottom, a.right)];
  final bPts = [(b.top, b.left), (b.bottom, b.right)];
  for (final pa in aPts) {
    for (final pb in bPts) {
      if (pa == pb) return true;
    }
  }
  return false;
}

void main(List<String> args) {
  final dir = Directory('${_corpusBase()}/vi');
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final sample = args.isNotEmpty ? vis.where((f) => f.path.contains(args[0])).toList() : vis.take(400).toList();

  // per class code: [objects with >=1 degenerate rect, chained-links, segments]
  final byClass = <int, List<int>>{};
  var wiryObjects = 0;

  const objectHeaderLeads = {0x10, 0x11, 0x12};
  for (final file in sample) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        if (decoded.tag != 'BDHb' && decoded.tag != 'BDHc') continue;
        final body = decoded.bytes;
        // Track the innermost object per graph.dart's grammar: group opens at
        // high-nibble-1 leads (object headers carry `02 fe <u16 kind>`),
        // closes at 08-0b, popped positionally.
        final stack = <int?>[]; // class kind, or null for a non-object group
        // per innermost object kind: running degenerate-rect chain state
        var degenerate = <int, int>{};
        var chained = <int, int>{};
        final previousEnd = <int, HeapRect?>{};
        void flush() {
          for (final kindEntry in degenerate.entries) {
            if (kindEntry.value >= 2) {
              wiryObjects++;
              final entry = byClass.putIfAbsent(kindEntry.key, () => [0, 0, 0]);
              entry[0]++;
              entry[1] += chained[kindEntry.key] ?? 0;
              entry[2] += kindEntry.value;
            }
          }
          degenerate = {};
          chained = {};
        }

        for (final span in walkHeapBody(body).spans) {
          final lead = span.lead;
          final offset = span.offset;
          final isGroupOpen =
              (objectHeaderLeads.contains(lead) || lead == 0x13) &&
              offset + 4 <= body.length &&
              (body[offset + 3] == 0xfb || body[offset + 3] == 0xfe || body[offset + 3] == 0xfd);
          if (isGroupOpen) {
            final isObject =
                objectHeaderLeads.contains(lead) &&
                offset + 9 <= body.length &&
                body[offset + 2] == 0x02 &&
                body[offset + 3] == 0xfe;
            stack.add(isObject ? (body[offset + 4] << 8) | body[offset + 5] : null);
            continue;
          }
          if (lead >= 0x08 && lead <= 0x0b) {
            if (stack.isNotEmpty) stack.removeLast();
            continue;
          }
          if (!span.isC4Record) continue;
          final record = c4FrameAt(body, offset, decoded.tag);
          final rect = record?.rect;
          if (rect == null) continue;
          final owner = stack.lastWhere((kind) => kind != null, orElse: () => -1) ?? -1;
          final isLine = rect.top == rect.bottom || rect.left == rect.right;
          if (!isLine) {
            previousEnd[owner] = null;
            continue;
          }
          degenerate.update(owner, (v) => v + 1, ifAbsent: () => 1);
          final prev = previousEnd[owner];
          if (prev != null && _sharesEndpoint(prev, rect)) {
            chained.update(owner, (v) => v + 1, ifAbsent: () => 1);
          }
          previousEnd[owner] = rect;
        }
        flush();
      }
    } catch (_) {}
  }

  stdout.writeln('sample ${sample.length} VIs · objects with >=2 line-like rects: $wiryObjects');
  final sorted = byClass.entries.toList()..sort((a, b) => b.value[2].compareTo(a.value[2]));
  stdout.writeln('class     objects  chainedLinks  segments');
  for (final entry in sorted.take(12)) {
    stdout.writeln(
      '0x${entry.key.toRadixString(16).padLeft(4, '0')}    '
      '${entry.value[0].toString().padLeft(7)}  ${entry.value[1].toString().padLeft(12)}  '
      '${entry.value[2].toString().padLeft(8)}',
    );
  }
}
