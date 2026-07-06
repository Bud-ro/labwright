import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Whole-corpus validation of the `0x1d` = wire hypothesis. For every BD
/// `0x1d` object: are its C4 rect records line-like (Manhattan h/v segments),
/// do consecutive segments share endpoints (a polyline), and do the polyline
/// ends land on/inside terminal-ish sibling bounds (wires connect terminals)?
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
  final sample = args.isNotEmpty ? vis.where((f) => f.path.contains(args[0])).toList() : vis;

  const objectHeaderLeads = {0x10, 0x11, 0x12};
  var wireObjects = 0;
  var withSegments = 0;
  var allSegmentsLineLike = 0;
  var allChained = 0;
  var segmentTotal = 0;
  var hSegments = 0, vSegments = 0;
  var endsOnTerminal = 0, endsChecked = 0;
  var fpWireObjects = 0;

  for (final file in sample) {
    try {
      final bytes = file.readAsBytesSync();
      final model = buildViModel(bytes);
      // terminal bounds per diagram for endpoint checking (absolute coords)
      for (final decoded in decodeSections(bytes)) {
        final isBd = decoded.tag == 'BDHb' || decoded.tag == 'BDHc';
        final isFp = decoded.tag == 'FPHb' || decoded.tag == 'FPHc';
        if (!isBd && !isFp) continue;
        final body = decoded.bytes;

        final terminalRects = <HeapRect>[];
        if (isBd) {
          for (final diagram in model.blockDiagrams) {
            for (final object in diagram.objects) {
              if (object.category == ViObjectKind.terminal && object.absBounds != null) {
                terminalRects.add(object.absBounds!);
              }
            }
          }
        }

        final stack = <int?>[];
        var rects = <HeapRect>[];
        var owner1d = false;
        var depthAtOpen = -1;
        bool innermostIs1d() {
          for (var i = stack.length - 1; i >= 0; i--) {
            if (stack[i] != null) return stack[i] == 0x1d;
          }
          return false;
        }

        void finishWire() {
          if (!owner1d) return;
          if (isFp) fpWireObjects++;
          if (!isBd) return;
          wireObjects++;
          if (rects.isEmpty) return;
          withSegments++;
          segmentTotal += rects.length;
          var lineLike = true;
          var chainedAll = true;
          for (var i = 0; i < rects.length; i++) {
            final rect = rects[i];
            final isH = rect.top == rect.bottom;
            final isV = rect.left == rect.right;
            if (isH) hSegments++;
            if (isV && !isH) vSegments++;
            if (!isH && !isV) lineLike = false;
            if (i > 0 && !_sharesEndpoint(rects[i - 1], rect)) chainedAll = false;
          }
          if (lineLike) allSegmentsLineLike++;
          if (chainedAll && rects.length >= 2) allChained++;
          // endpoint-on-terminal check (rects are heap-relative like bounds;
          // compare against relative terminal bounds is wrong — approximate by
          // checking proximity to ANY terminal rect corner within 24px)
          for (final end in [rects.first, rects.last]) {
            endsChecked++;
            final ex = end.left;
            final ey = end.top;
            for (final terminal in terminalRects) {
              final inX = ex >= terminal.left - 24 && ex <= terminal.right + 24;
              final inY = ey >= terminal.top - 24 && ey <= terminal.bottom + 24;
              if (inX && inY) {
                endsOnTerminal++;
                break;
              }
            }
          }
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
            final kind = isObject ? (body[offset + 4] << 8) | body[offset + 5] : null;
            if (kind == 0x1d && !owner1d) {
              owner1d = true;
              depthAtOpen = stack.length;
              rects = [];
            }
            stack.add(kind);
            continue;
          }
          if (lead >= 0x08 && lead <= 0x0b) {
            if (stack.isNotEmpty) stack.removeLast();
            if (owner1d && stack.length <= depthAtOpen) {
              finishWire();
              owner1d = false;
            }
            continue;
          }
          if (!owner1d || !span.isC4Record || !innermostIs1d()) continue;
          final rect = c4FrameAt(body, offset, decoded.tag)?.rect;
          if (rect != null) rects.add(rect);
        }
      }
    } catch (_) {}
  }

  stdout
    ..writeln('sample ${sample.length} VIs')
    ..writeln('0x1d objects: BD=$wireObjects FP=$fpWireObjects · with rect records: $withSegments')
    ..writeln('all-segments-line-like: $allSegmentsLineLike/$withSegments')
    ..writeln('fully endpoint-chained (>=2 segs): $allChained')
    ..writeln('segments: $segmentTotal (h=$hSegments v=$vSegments)')
    ..writeln('polyline ends near a terminal rect: $endsOnTerminal/$endsChecked');
}
