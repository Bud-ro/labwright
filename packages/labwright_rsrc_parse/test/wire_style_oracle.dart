library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

typedef Raster = ({int width, int height, Uint8List rgba});

Raster decodePngRaster(Uint8List png) {
  final view = ByteData.sublistView(png);
  var i = 8;
  int? width, height, colorType, bitDepth;
  Uint8List? palette;
  final idat = BytesBuilder(copy: false);
  while (i + 12 <= png.length) {
    final len = view.getUint32(i);
    final type = String.fromCharCodes(png, i + 4, i + 8);
    final start = i + 8;
    if (type == 'IHDR') {
      width = view.getUint32(start);
      height = view.getUint32(start + 4);
      bitDepth = png[start + 8];
      colorType = png[start + 9];
      if (png[start + 12] != 0) throw UnsupportedError('interlaced');
    } else if (type == 'PLTE') {
      palette = Uint8List.sublistView(png, start, start + len);
    } else if (type == 'IDAT') {
      idat.add(Uint8List.sublistView(png, start, start + len));
    } else if (type == 'IEND') {
      break;
    }
    i = start + len + 4;
  }
  if (width == null || height == null) throw const FormatException('no IHDR');
  if (bitDepth != 8) throw UnsupportedError('bitDepth $bitDepth');
  final channels = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw UnsupportedError('colorType $colorType'),
  };
  final raw = ZLibDecoder().convert(idat.takeBytes());
  final stride = width * channels;
  final out = Uint8List(width * height * 4);
  final prev = Uint8List(stride);
  final curr = Uint8List(stride);
  var p = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[p++];
    for (var x = 0; x < stride; x++) {
      final rawByte = raw[p + x];
      final a = x >= channels ? curr[x - channels] : 0;
      final b = prev[x];
      final c = x >= channels ? prev[x - channels] : 0;
      curr[x] = switch (filter) {
        0 => rawByte,
        1 => rawByte + a,
        2 => rawByte + b,
        3 => rawByte + ((a + b) >> 1),
        4 => rawByte + _paeth(a, b, c),
        _ => throw FormatException('filter $filter'),
      };
    }
    p += stride;
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      switch (colorType) {
        case 0:
          out[o] = out[o + 1] = out[o + 2] = curr[x];
          out[o + 3] = 255;
        case 2:
          out[o] = curr[x * 3];
          out[o + 1] = curr[x * 3 + 1];
          out[o + 2] = curr[x * 3 + 2];
          out[o + 3] = 255;
        case 3:
          final pi = curr[x] * 3;
          out[o] = palette![pi];
          out[o + 1] = palette[pi + 1];
          out[o + 2] = palette[pi + 2];
          out[o + 3] = 255;
        case 4:
          out[o] = out[o + 1] = out[o + 2] = curr[x * 2];
          out[o + 3] = curr[x * 2 + 1];
        case 6:
          out[o] = curr[x * 4];
          out[o + 1] = curr[x * 4 + 1];
          out[o + 2] = curr[x * 4 + 2];
          out[o + 3] = curr[x * 4 + 3];
      }
    }
    prev.setAll(0, curr);
  }
  return (width: width, height: height, rgba: out);
}

int _paeth(int a, int b, int c) {
  final pa = (b - c).abs(), pb = (a - c).abs(), pc = (a + b - c - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

List<File> listSnippetPngs(Directory corpusViDir) {
  if (!corpusViDir.existsSync()) return const [];
  return [
    for (final d in const ['rcpacini_VI-Snippets', 'rcpacini_LabVIEW-VI-Snippet'])
      if (Directory('${corpusViDir.path}/$d').existsSync())
        ...Directory(
          '${corpusViDir.path}/$d',
        ).listSync(recursive: true, followLinks: false).whereType<File>().where((f) => f.path.endsWith('.png')),
  ]..sort((a, b) => a.path.compareTo(b.path));
}

bool objectVisibleInRender(ViDiagram bd, int oid) {
  var o = bd.byId[oid];
  for (var i = 0; o != null && i < 64; i++) {
    final p = o.parentOid == null ? null : bd.byId[o.parentOid!];
    if (p != null && o.kind == 0x1b && kMultiFrameStructureClasses.contains(p.objectClass)) {
      var idx = 0;
      for (final sib in bd.objects) {
        if (sib.parentOid == p.oid && sib.kind == 0x1b) {
          if (sib.oid == o.oid) break;
          idx++;
        }
      }
      if (idx != p.visibleFrameIndex) return false;
    }
    o = p;
  }
  return true;
}

typedef Interior = ({int left, int top, int right, int bottom});

typedef Registration = ({int dx, int dy, int score, int max, bool leafMode});

Registration registerDiagram(ViDiagram bd, Raster raster, Interior interior) {
  final w = interior.right - interior.left, h = interior.bottom - interior.top;
  if (w <= 0 || h <= 0) return (dx: 0, dy: 0, score: 0, max: 1, leafMode: false);
  final colInk = List<double>.filled(w, 0), rowInk = List<double>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = ((y + interior.top) * raster.width + (x + interior.left)) * 4;
      if (raster.rgba[o] < 240 || raster.rgba[o + 1] < 240 || raster.rgba[o + 2] < 240) {
        colInk[x]++;
        rowInk[y]++;
      }
    }
  }
  final xEdges = <int, double>{}, yEdges = <int, double>{};
  for (final o in bd.objects) {
    final r = o.absBounds;
    if (r == null || r.width < 4 || r.height < 4) continue;
    if (!objectVisibleInRender(bd, o.oid)) continue;
    xEdges[r.left] = (xEdges[r.left] ?? 0) + r.height;
    xEdges[r.right - 1] = (xEdges[r.right - 1] ?? 0) + r.height;
    yEdges[r.top] = (yEdges[r.top] ?? 0) + r.width;
    yEdges[r.bottom - 1] = (yEdges[r.bottom - 1] ?? 0) + r.width;
  }
  if (xEdges.isEmpty) return (dx: 0, dy: 0, score: 0, max: 1, leafMode: false);
  int best1d(Map<int, double> edges, List<double> prof) {
    var bestS = -1.0;
    var bestD = 0;
    var lo = 1 << 30, hi = -1 << 30;
    for (final k in edges.keys) {
      if (k < lo) lo = k;
      if (k > hi) hi = k;
    }
    for (var d = lo - 40; d <= hi; d++) {
      var s = 0.0;
      edges.forEach((pos, wt) {
        final i = pos - d;
        if (i >= 0 && i < prof.length) s += wt * prof[i];
      });
      if (s > bestS) {
        bestS = s;
        bestD = d;
      }
    }
    return bestD;
  }

  final dx0 = best1d(xEdges, colInk), dy0 = best1d(yEdges, rowInk);

  var ringPts = <(int, int)>[];
  for (final o in bd.objects) {
    final r = o.absBounds;
    if (r == null) continue;
    if (!const {0x20, 0x21, 0xcd, 0x2c}.contains(o.kind)) continue;
    if (r.width < 40 || r.height < 30) continue;
    if (!objectVisibleInRender(bd, o.oid)) continue;
    _addPerimeter(ringPts, r);
  }
  var leafMode = false;
  if (ringPts.length < 200) {
    leafMode = true;
    ringPts = <(int, int)>[];
    for (final o in bd.objects) {
      final r = o.absBounds;
      if (r == null || r.width < 8 || r.height < 8 || r.width > 80 || r.height > 80) continue;
      if (o.kind == 0x0a || o.kind == 0x95) continue;
      if (!objectVisibleInRender(bd, o.oid)) continue;
      _addPerimeter(ringPts, r);
    }
  }
  if (ringPts.isEmpty) return (dx: 0, dy: 0, score: 0, max: 1, leafMode: leafMode);
  bool ink(int px, int py) {
    if (px < interior.left || px >= interior.right || py < interior.top || py >= interior.bottom) return false;
    final o = (py * raster.width + px) * 4;
    return !(raster.rgba[o] > 245 && raster.rgba[o + 1] > 245 && raster.rgba[o + 2] > 245);
  }

  var fine = (dx: 0, dy: 0, score: -1);
  for (var dx = dx0 - 8; dx <= dx0 + 8; dx++) {
    for (var dy = dy0 - 8; dy <= dy0 + 8; dy++) {
      var s = 0;
      for (final (x, y) in ringPts) {
        if (ink(x - dx + interior.left, y - dy + interior.top)) s++;
      }
      if (s > fine.score) fine = (dx: dx, dy: dy, score: s);
    }
  }
  return (dx: fine.dx, dy: fine.dy, score: fine.score, max: ringPts.length, leafMode: leafMode);
}

void _addPerimeter(List<(int, int)> pts, HeapRect r) {
  for (var x = r.left; x < r.right; x++) {
    pts.add((x, r.top));
    pts.add((x, r.bottom - 1));
  }
  for (var y = r.top + 1; y < r.bottom - 1; y++) {
    pts.add((r.left, y));
    pts.add((r.right - 1, y));
  }
}

class WireRun {
  WireRun(this.sigOid, this.horizontal, this.axisPos, this.lo, this.hi);
  final int sigOid;
  final bool horizontal;

  final int axisPos;

  final int lo, hi;

  String? style;

  int? color;
}

List<WireRun> wireRuns(ViDiagram bd) {
  final runs = <WireRun>[];
  final shells = <HeapRect>[
    for (final w in bd.wires)
      for (final oid in w.endpointOids)
        if (bd.endpointConstantBounds(oid) case final s?) s,
  ];
  for (final w in bd.wires) {
    if (w.endpointOids.length != 2) continue;
    if (!objectVisibleInRender(bd, w.signalOid)) continue;
    final rects = [for (var i = 0; i < 2; i++) w.endpointAttachRects[i] ?? w.endpointAnchors[i]];
    if (rects.any((r) => r == null || r.width <= 0 || r.height <= 0)) continue;
    final a = rects[0]!, b = rects[1]!;
    final candidates = <WireRun>[];
    if (w.route == null || w.route!.segmentLengths.isEmpty) {
      final cyA = a.top + a.height ~/ 2, cyB = b.top + b.height ~/ 2;
      final cxA = a.left + a.width ~/ 2, cxB = b.left + b.width ~/ 2;
      if (cyA == cyB) {
        final lo = a.right <= b.left ? a.right : b.right;
        final hi = a.right <= b.left ? b.left : a.left;
        if (hi - lo >= 1) candidates.add(WireRun(w.signalOid, true, cyA, lo - 1, hi + 1));
      } else if (cxA == cxB) {
        final lo = a.bottom <= b.top ? a.bottom : b.bottom;
        final hi = a.bottom <= b.top ? b.top : a.top;
        if (hi - lo >= 1) candidates.add(WireRun(w.signalOid, false, cxA, lo - 1, hi + 1));
      }
    } else if (w.endpointAttachRects[0] != null) {
      candidates.addAll(_routeRuns(w, a, b) ?? const []);
    }
    for (final run in candidates) {
      runs.addAll(clipRunOutOfRects(run, shells));
    }
  }
  return runs;
}

List<WireRun> clipRunOutOfRects(WireRun run, List<HeapRect> rects) {
  var spans = <(int, int)>[(run.lo, run.hi)];
  for (final rect in rects) {
    final inBand = run.horizontal
        ? run.axisPos >= rect.top && run.axisPos <= rect.bottom
        : run.axisPos >= rect.left && run.axisPos <= rect.right;
    if (!inBand) continue;
    final cutLo = (run.horizontal ? rect.left : rect.top) - 1;
    final cutHi = (run.horizontal ? rect.right : rect.bottom) + 1;
    final next = <(int, int)>[];
    for (final (lo, hi) in spans) {
      if (hi < cutLo || lo > cutHi) {
        next.add((lo, hi));
        continue;
      }
      if (lo < cutLo) next.add((lo, cutLo - 1));
      if (hi > cutHi) next.add((cutHi + 1, hi));
    }
    spans = next;
    if (spans.isEmpty) break;
  }
  return [
    for (final (lo, hi) in spans)
      if (hi - lo >= 1) WireRun(run.sigOid, run.horizontal, run.axisPos, lo, hi),
  ];
}

List<WireRun>? _routeRuns(ViWire w, HeapRect a, HeapRect b) {
  final route = w.route!;
  final direction = route.direction;
  if (direction == null) return null;
  var x = a.left + a.width ~/ 2, y = a.top + a.height ~/ 2;
  final bx = b.left + b.width ~/ 2, by = b.top + b.height ~/ 2;
  var horizontal = direction.isHorizontal;
  var sign = direction.dx + direction.dy;
  final pts = <(int, int)>[(x, y)];
  for (var i = 0; i < route.segmentLengths.length; i++) {
    final len = route.segmentLengths[i];
    if (i > 0) sign = route.jointSigns[i - 1];
    if (horizontal) {
      x += sign * len;
    } else {
      y += sign * len;
    }
    pts.add((x, y));
    horizontal = !horizontal;
  }
  if (horizontal) {
    if ((y - by).abs() > 3) return null;
    pts.add((bx, y));
  } else {
    if ((x - bx).abs() > 3) return null;
    pts.add((x, by));
  }
  final runs = <WireRun>[];
  for (var i = 0; i + 1 < pts.length; i++) {
    final (x0, y0) = pts[i];
    final (x1, y1) = pts[i + 1];
    if (y0 == y1 && (x1 - x0).abs() >= 5) {
      runs.add(WireRun(w.signalOid, true, y0, (x0 < x1 ? x0 : x1) + 2, (x0 < x1 ? x1 : x0) - 1));
    } else if (x0 == x1 && (y1 - y0).abs() >= 5) {
      runs.add(WireRun(w.signalOid, false, x0, (y0 < y1 ? y0 : y1) + 2, (y0 < y1 ? y1 : y0) - 1));
    }
  }
  return runs;
}

void sampleRun(WireRun run, Raster raster, Interior interior, Registration reg) {
  int pxX(int diagX) => diagX - reg.dx + interior.left;
  int pxY(int diagY) => diagY - reg.dy + interior.top;
  bool inbounds(int px, int py) =>
      px >= interior.left && px < interior.right && py >= interior.top && py < interior.bottom;
  (int, int, int) at(int px, int py) {
    final o = (py * raster.width + px) * 4;
    return (raster.rgba[o], raster.rgba[o + 1], raster.rgba[o + 2]);
  }

  final colorVotes = <int, int>{};
  for (var c = run.lo + 1; c < run.hi - 1; c++) {
    for (var d = -1; d <= 1; d++) {
      final (px, py) = run.horizontal ? (pxX(c), pxY(run.axisPos + d)) : (pxX(run.axisPos + d), pxY(c));
      if (!inbounds(px, py)) continue;
      final (r, g, b) = at(px, py);
      if (r > 245 && g > 245 && b > 245) continue;
      final rgb = (r << 16) | (g << 8) | b;
      colorVotes[rgb] = (colorVotes[rgb] ?? 0) + 1;
    }
  }
  if (colorVotes.isEmpty) {
    run.style = 'blank';
    return;
  }
  final ranked = colorVotes.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
  final wireColor = ranked.first.key;
  var votes = 0;
  for (final e in ranked) {
    votes += e.value;
  }
  if (ranked.first.value * 10 >= votes * 7) run.color = wireColor;
  if (run.hi - run.lo < 14) return;

  final masks = <int, int>{};
  var clean = 0, total = 0;
  for (var c = run.lo + 1; c < run.hi - 1; c++) {
    total++;
    var mask = 0;
    var bad = false;
    for (var d = -3; d <= 3; d++) {
      final (px, py) = run.horizontal ? (pxX(c), pxY(run.axisPos + d)) : (pxX(run.axisPos + d), pxY(c));
      if (!inbounds(px, py)) {
        bad = true;
        break;
      }
      final (r, g, b) = at(px, py);
      final rgb = (r << 16) | (g << 8) | b;
      final isBg = r > 245 && g > 245 && b > 245;
      if (rgb == wireColor && d.abs() <= 2) {
        mask |= 1 << (d + 2);
      } else if (!isBg) {
        bad = true;
        break;
      }
    }
    if (bad) continue;
    clean++;
    masks[c] = mask;
  }
  if (clean < 10 || clean * 2 < total) {
    run.style = 'unsampled';
    return;
  }
  run.style = classifyCycle(masks, coverage: clean / total);
}

const recognizedCycles = <String, String>{
  'p1:00100': 'solid1px',
  'p1:00110': 'solid2px',
  'p1:01100': 'solid2px',
  'p1:01010': 'hollowDouble',
  'p2:00000,00100': 'dotted',
  'p2:00000,00010': 'dotted',
  'p2:00000,01000': 'dotted',
  'p2:00010,00100': 'dottedAlternating',
  'p2:00100,01000': 'dottedAlternating',
  'p4:00010,00110,00100,00110': 'zigzag',
  'p4:00100,01100,01000,01100': 'zigzag',
  'p4:00100,01110,01010,01110': 'chainLink',
  'p4:00101,01111,01010,01111': 'chainLinkWide',
  'p4:01010,01010,01110,01110': 'braid',
  'p2:01010,01110': 'braidDense',
  'p4:01001,01101,01111,01011': 'braidWide',
  'p2:01011,01101': 'braidDenseWide',
  'p8:00010,01010,00010,01110,01000,01010,01000,01110': 'weave',
};

String classifyCycle(Map<int, int> masks, {double coverage = 1.0}) {
  final xs = masks.keys.toList()..sort();
  int? period;
  for (final p in const [1, 2, 3, 4, 5, 6, 7, 8]) {
    var agree = 0, pairs = 0;
    for (final x in xs) {
      final other = masks[x + p];
      if (other == null) continue;
      pairs++;
      if (other == masks[x]) agree++;
    }
    if (pairs >= 6 && agree / pairs >= 0.95) {
      period = p;
      break;
    }
  }
  if (period == null) return 'aperiodic';
  final cyc = List<int>.filled(period, 0);
  for (var ph = 0; ph < period; ph++) {
    final votes = <int, int>{};
    for (final x in xs) {
      if ((x % period + period) % period == ph) votes[masks[x]!] = (votes[masks[x]!] ?? 0) + 1;
    }
    if (votes.isEmpty) return 'aperiodic';
    cyc[ph] = (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }
  var best = cyc;
  for (var r = 1; r < period; r++) {
    final rot = [for (var i = 0; i < period; i++) cyc[(i + r) % period]];
    for (var i = 0; i < period; i++) {
      if (rot[i] != best[i]) {
        if (rot[i] < best[i]) best = rot;
        break;
      }
    }
  }
  if (best.every((m) => m == 0)) return 'blank';
  final key = 'p$period:${best.map((m) => m.toRadixString(2).padLeft(5, '0')).join(',')}';
  final verdict = recognizedCycles[key] ?? 'unclassified:$key';
  if (period >= 2 && coverage < 0.8) return 'lowcover:$verdict';
  return verdict;
}
