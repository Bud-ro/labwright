import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Third wire hunt: the two remaining candidates from the wire research
/// (recorded on [HeapObjectClass.bdWire] in graph.dart).
///
/// 1. **Un-walked heap content**: where `walkHeapBody` stops early in a BD
///    heap, what lead bytes/structure sits in the un-walked remainder?
/// 2. **Rect-aliased segments**: 8-byte `C4 2D`-shaped records whose "rect"
///    reads as a degenerate line (top==bottom or left==right) — the shape a
///    wire segment would take. How many, and do they chain (end of one ==
///    start of next), which would be a wire polyline in disguise?
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

void main(List<String> args) {
  final dir = Directory('${_corpusBase()}/vi');
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final sample = args.isNotEmpty ? vis.where((f) => f.path.contains(args[0])).toList() : vis.take(200).toList();

  var heaps = 0, incompleteWalks = 0;
  final stopLeads = <int, int>{};
  var unwalkedBytes = 0, walkedBytes = 0;

  var rectRecords = 0, degenerateRects = 0, chainedSegments = 0;
  final chainsPerHeap = <int>[];

  for (final file in sample) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        if (decoded.tag != 'BDHb' && decoded.tag != 'BDHc') continue;
        heaps++;
        final body = decoded.bytes;
        final walk = walkHeapBody(body);
        walkedBytes += walk.coveredBytes;
        if (!walk.complete) {
          incompleteWalks++;
          unwalkedBytes += walk.bodyBytes - walk.coveredBytes;
          stopLeads.update(walk.stoppedLead ?? -1, (v) => v + 1, ifAbsent: () => 1);
          if (incompleteWalks <= 4) {
            final at = walk.stoppedAtOffset!;
            final end = (at + 48).clamp(0, body.length);
            final hex = [
              for (var i = at; i < end; i++) body[i].toRadixString(16).padLeft(2, '0'),
            ].join(' ');
            stdout.writeln('  STOP ${file.path.split('/').last} @$at/${walk.bodyBytes}: $hex');
          }
        }

        // rect-aliased segment scan: consecutive degenerate "rects"
        HeapRect? previousEnd;
        var chain = 0;
        for (final record in scanC4Records(body, decoded.tag)) {
          final rect = record.rect;
          if (rect == null) continue;
          rectRecords++;
          final isLine = rect.top == rect.bottom || rect.left == rect.right;
          if (!isLine) {
            previousEnd = null;
            continue;
          }
          degenerateRects++;
          if (previousEnd != null && (previousEnd.bottom == rect.top && previousEnd.right == rect.left)) {
            chainedSegments++;
            chain++;
          }
          previousEnd = rect;
        }
        if (chain > 0) chainsPerHeap.add(chain);
      }
    } catch (_) {}
  }

  stdout.writeln('sample ${sample.length} VIs · $heaps BD heaps');
  stdout.writeln(
    'incomplete walks: $incompleteWalks · un-walked bytes: $unwalkedBytes '
    '(walked $walkedBytes)',
  );
  final sortedLeads = stopLeads.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sortedLeads.take(8)) {
    stdout.writeln('  stop lead 0x${entry.key.toRadixString(16)}: ${entry.value}');
  }
  stdout.writeln(
    'rect-shaped C4 records: $rectRecords · degenerate (line-like): $degenerateRects '
    '· chained end-to-start: $chainedSegments across ${chainsPerHeap.length} heaps',
  );
}
