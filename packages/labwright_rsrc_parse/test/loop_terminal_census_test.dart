@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the structure-terminal glyph decode
/// ([ViDiagram.terminalDco] / [ViDiagram.terminalGlyphHidden]) and the
/// constant-endpoint decode ([ViDiagram.endpointConstant] /
/// [ViDiagram.endpointConstantBounds]) — every number those doc comments
/// cite, recomputed from scratch and pinned exactly against the
/// `structure_terminals` snapshot section. One extra full-model corpus pass.
///
/// Three censuses share the pass:
///
///  1. **Terminal glyphs** — per [ViHeapObject.termBmp] value: the carrier
///     population, how its DCO resolves (unique / none / ambiguous), and the
///     resolved DCO's hidden bit (`0x800000`) crossed with whether the DCO is
///     wired (participates in any signal). The hidden×wired cross is what
///     backs the render law: LabVIEW's hidden loop terminals are unwired.
///  2. **Free hidden DCOs** — endpoint DCOs carrying the hidden bit with no
///     termBounds terminal claiming them, keyed by parent kind (the
///     expandable-node terminal population the accessor deliberately does
///     not interpret).
///  3. **Constant endpoints** — signal endpoints wrapping a `0x13` constant:
///     value decode presence, value-shell resolution, which endpoint slot of
///     a two-endpoint signal holds the constant, and whether the stored
///     route ships a closed polyline from the shell's centre
///     ([ViWire.routePoints] — closure is the zero-slack proof of the
///     centre attach convention).
Map<String, int> _census(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final ViModel model;
  try {
    model = buildViModelFromDecoded(decodeSections(bytes));
  } catch (_) {
    return c;
  }
  for (final d in model.blockDiagrams) {
    final byId = d.byId;
    final wired = <int>{for (final w in d.wires) ...w.endpointOids};
    final claimed = <int>{};

    for (final o in d.objects) {
      if (o.termBounds == null || o.termBmp == null) continue;
      final bmp = o.termBmp!;
      bump('bmp${bmp}n');
      final dco = d.terminalDco(o.oid);
      if (dco == null) {
        // Split "no candidate" from "ambiguous" the way terminalDco does not
        // need to: count childRef targets that are back-linked DCOs.
        final candidates = (o.typedRefs[HeapRefKind.childRef] ?? const <int>[]).where((t) {
          final obj = byId[t];
          return obj != null &&
              kSignalEndpointDcoKinds.contains(obj.kind) &&
              (obj.typedRefs[HeapRefKind.dcoRef] ?? const <int>[]).contains(o.oid);
        }).length;
        bump('bmp$bmp${candidates == 0 ? 'DcoNone' : 'DcoMulti'}');
        continue;
      }
      claimed.add(dco.oid);
      final hidden = ((dco.objFlags ?? 0) & 0x800000) != 0;
      bump('bmp$bmp${hidden ? 'Hidden' : 'Shown'}${wired.contains(dco.oid) ? 'Wired' : 'Unwired'}');
    }

    for (final o in d.objects) {
      if (!kSignalEndpointDcoKinds.contains(o.kind)) continue;
      if (((o.objFlags ?? 0) & 0x800000) == 0 || claimed.contains(o.oid)) continue;
      final p = byId[o.parentOid ?? -1];
      bump('freeHiddenDcoParent${p == null ? 'None' : p.kind.toRadixString(16)}');
    }

    for (final w in d.wires) {
      final shells = <HeapRect?>[];
      for (final e in w.endpointOids) {
        final constant = d.endpointConstant(e);
        if (constant == null) {
          shells.add(null);
          continue;
        }
        bump('constEp');
        if (constant.constNumeric != null || constant.constText != null || constant.constBool != null) {
          bump('constEpValue');
        }
        if (d.children(e).where((k) => k.kind == HeapObjectClass.bdConstDco.code).length > 1) {
          bump('constEpMultiK13');
        }
        final boxes = d.children(constant.oid).where((g) => g.absBounds != null).length;
        if (boxes == 0) bump('constEpNoShell');
        if (boxes > 1) bump('constEpMultiShell');
        shells.add(d.endpointConstantBounds(e));
      }
      if (w.endpointOids.length != 2 || shells.every((s) => s == null)) continue;
      bump('constSig2ep');
      if (shells[0] != null && shells[1] != null) bump('constSigBothEnds');
      bump(shells[0] != null ? 'constSigAtIdx0' : 'constSigAtIdx1');
      if (w.route == null) {
        bump('constSigNoRoute');
      } else if (w.routePoints != null) {
        bump('constSigShipped');
      } else if (d.wireAttachPoint(w.endpointOids[0]) == null || d.wireAttachPoint(w.endpointOids[1]) == null) {
        bump('constSigNoFarAnchor');
      } else {
        bump('constSigCloseMiss');
      }
    }
  }
  return c;
}

void main() {
  test('structure-terminal glyph + constant-endpoint corpus census', () async {
    final merged = <String, int>{};
    for (final c in await corpusParallel(corpusVis(), _census)) {
      c.forEach((k, v) => merged[k] = (merged[k] ?? 0) + v);
    }
    expectCorpusSnapshot('structure_terminals', merged);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('crc8: N feeders resolve to their constant boxes; hidden i glyphs decode', () {
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    if (!crc8.existsSync()) {
      markTestSkipped('crc8 snippet not fetched');
      return;
    }
    final d = buildViModel(extractSnippetVi(crc8.readAsBytesSync())!).blockDiagrams.single;

    // Terminal glyph visibility, straight from LabVIEW's own raster in the
    // snippet: the four for loops (oids 86/164/571/3042) all draw `N`; only
    // 86 and 3042 draw `i` (the others' unwired iteration terminals are
    // hidden). Terminal carrier oid -> (dco oid, hidden).
    const glyphs = {
      119: (118, false), // i, "Create CRC-8 LUT" loop 86 — drawn
      194: (193, true), //  i, inner 8-bit loop 164 — absent in the render
      605: (604, true), //  i, "Calculate CRC-8" loop 571 — absent
      3063: (3062, false), // i, disabled LUT loop 3042 — drawn
      89: (91, false), //   N, loop 86 — drawn, fed by the "bytes" 256 box
      167: (169, false), // N, loop 164 — drawn, fed by the "8-bits" 8 box
      574: (576, false), // N, loop 571 — drawn bare (count unwired)
      3045: (3047, false), // N, loop 3042 — drawn, fed by a 256 box
    };
    glyphs.forEach((oid, want) {
      expect(d.terminalDco(oid)?.oid, want.$1, reason: 'terminal $oid DCO');
      expect(d.terminalGlyphHidden(oid), want.$2, reason: 'terminal $oid hidden');
    });

    // N-feeder linkage: the count signal's far endpoint wraps the constant
    // LabVIEW draws beside `N`. Endpoint oid -> (value, shell t,l,b,r).
    const feeders = {
      389: (256, (374, 94, 393, 150)), // "bytes 256" beside loop 86's N
      133: (8, (432, 209, 451, 255)), // "8-bits 8" beside loop 164's N
      3030: (256, (197, 189, 216, 214)), // 256 beside loop 3042's N
    };
    feeders.forEach((oid, want) {
      expect(d.endpointConstant(oid)?.constNumeric, want.$1, reason: 'endpoint $oid value');
      final r = d.endpointConstantBounds(oid)!;
      expect((r.top, r.left, r.bottom, r.right), want.$2, reason: 'endpoint $oid shell');
    });

    // The feeder wires ship exact closed polylines from the shell centre to
    // the N terminal's attach rect (previously they anchored on a degenerate
    // zero-area segment and routed to nothing).
    const routes = {
      399: [(x: 122, y: 383), (x: 166, y: 383)], // 256 -> loop 86 N
      375: [(x: 232, y: 441), (x: 271, y: 441)], // 8 -> loop 164 N
      3126: [(x: 201, y: 206), (x: 230, y: 206)], // 256 -> loop 3042 N
    };
    for (final w in d.wires) {
      final want = routes[w.signalOid];
      if (want != null) expect(w.routePoints, want, reason: 'signal ${w.signalOid}');
    }
  });
}
