@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('crc8: N feeders resolve to their constant boxes; hidden i glyphs decode', () {
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    final d = buildViModel(extractSnippetVi(crc8.readAsBytesSync())!).blockDiagrams.single;

    const glyphs = {
      119: (118, false, 0x020140),
      194: (193, true, 0x820140),
      605: (604, true, 0x820140),
      3063: (3062, false, 0x020140),
      89: (91, false, 0x020000),
      167: (169, false, 0x020000),
      574: (576, false, 0x020000),
      3045: (3047, false, 0x020000),
    };
    glyphs.forEach((oid, want) {
      final dco = d.terminalDco(oid);
      expect(dco?.oid, want.$1, reason: 'terminal $oid DCO');
      expect(d.terminalGlyphHidden(oid), want.$2, reason: 'terminal $oid hidden');
      expect(dco?.objFlags, want.$3, reason: 'terminal $oid DCO objFlags');
    });

    const feeders = {
      389: (256, (374, 94, 393, 150)),
      133: (8, (432, 209, 451, 255)),
      3030: (256, (197, 189, 216, 214)),
    };
    feeders.forEach((oid, want) {
      expect(d.endpointConstant(oid)?.constNumeric, want.$1, reason: 'endpoint $oid value');
      final r = d.endpointConstantBounds(oid)!;
      expect((r.top, r.left, r.bottom, r.right), want.$2, reason: 'endpoint $oid shell');
    });

    const routes = {
      399: [(x: 122, y: 383), (x: 166, y: 383)],
      375: [(x: 232, y: 441), (x: 271, y: 441)],
      3126: [(x: 201, y: 206), (x: 230, y: 206)],
    };
    final matched = <int>{};
    for (final w in d.wires) {
      final want = routes[w.signalOid];
      if (want == null) continue;
      matched.add(w.signalOid);
      expect(w.routePoints, want, reason: 'signal ${w.signalOid}');
    }
    expect(matched, routes.keys.toSet(), reason: 'all three feeder signals present');

    final lut = d.wires.singleWhere((w) => w.signalOid == 879);
    expect(lut.routeTreeFidelity, WireRouteFidelity.closed, reason: 'LUT wire tier');
    expect(lut.routeTree!.polylines, [
      [(x: 483, y: 178), (x: 512, y: 178), (x: 512, y: 267), (x: 524, y: 267)],
      [(x: 512, y: 178), (x: 842, y: 178), (x: 842, y: 305), (x: 861, y: 305)],
    ], reason: 'LUT wire runs');
    expect(lut.routeTree!.junctions, [(x: 512, y: 178)], reason: 'LUT junction');
  });
}
