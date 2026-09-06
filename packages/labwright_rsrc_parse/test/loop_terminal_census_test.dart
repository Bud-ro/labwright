@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'test_util.dart';

/// The flat serialized width of a fixed-width numeric VCTP kind, or null for
/// every other kind — the typed tier's `_flatNumericSize` gate, restated so
/// the census scores the law rather than the implementation.
int? _flatWidth(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

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
///     resolved DCO's hidden bit ([kTerminalGlyphHiddenFlag]) crossed with
///     whether the DCO is wired (participates in any signal). The
///     hidden×wired cross is what
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
///  4. **Typed-constant framing** — how a constant's payload fits the layout
///     law its resolved data-space type implies in the typed tier of
///     [decodeBdConstValues]: the numeric-scalar width (`num*`), the
///     `[u32 dim]*[elements]` array law (`arr*`), and the
///     `[u32 length][length bytes]` string law (`str*`) plus how that
///     reading compares with the heap-parse printable filter it supersedes.
///     Needs the resolved data-space type, so it rides this full-model pass
///     rather than the type-free `bd_const_values` census.
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
      final hidden = ((dco.objFlags ?? 0) & kTerminalGlyphHiddenFlag) != 0;
      bump('bmp$bmp${hidden ? 'Hidden' : 'Shown'}${wired.contains(dco.oid) ? 'Wired' : 'Unwired'}');
    }

    for (final o in d.objects) {
      if (!kSignalEndpointDcoKinds.contains(o.kind)) continue;
      if (((o.objFlags ?? 0) & kTerminalGlyphHiddenFlag) == 0 || claimed.contains(o.oid)) continue;
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
        // Which value-shell kind the missed constant sits on — the doc's
        // "composite shell" attribution is pinned here, not asserted blind.
        final srcIdx = shells[0] != null ? 0 : 1;
        final constant = d.endpointConstant(w.endpointOids[srcIdx]);
        final shell = constant == null
            ? null
            : d.children(constant.oid).firstWhere((g) => g.absBounds != null, orElse: () => constant);
        bump('constCloseMissShell${(shell?.kind ?? -1).toRadixString(16)}');
      }
    }

    for (final o in d.objects) {
      if (o.kind != HeapObjectClass.bdConstDco.code) continue;
      final flat = o.constValueRaw;
      final resolved = o.resolvedType;
      if (flat == null || resolved == null) continue;
      // The typed tier's numeric-scalar and array framing laws
      // (`_typedBdConstDecode`), pinned alongside the string law below.
      final scalarWidth = _flatWidth(resolved.kind);
      if (scalarWidth != null) {
        bump('numTyped');
        if (flat.isEmpty) {
          bump('numEmpty');
        } else if (flat.length > scalarWidth) {
          bump('numWider');
        } else if (flat.length < scalarWidth) {
          bump(resolved.kind == ViDataType.sgl || resolved.kind == ViDataType.dbl ? 'numNarrowFloat' : 'numNarrow');
        } else {
          bump('numExact');
        }
      }
      if (resolved.kind == ViDataType.array) {
        bump('arrTyped');
        final element = o.resolvedElementType;
        final dims = resolved.dimCount;
        final elementWidth = element == null ? null : _flatWidth(element.kind);
        if (elementWidth == null || dims == null || dims < 1 || dims > 8) {
          bump('arrElemNotNumeric');
        } else if (flat.length < 4 * dims) {
          bump('arrDimsTruncated');
        } else {
          final view = ByteData.sublistView(flat);
          var count = 1;
          for (var i = 0; i < dims; i++) {
            count *= view.getUint32(4 * i);
          }
          if (flat.length == 4 * dims + count * elementWidth) {
            bump('arrFits');
          } else if (count == 0 && flat.length == 4 * dims + 1 && flat.last == 0) {
            bump('arrEmptyPad');
          } else {
            bump('arrNeither');
          }
        }
      }
      if (resolved.kind != ViDataType.string) continue;
      bump('strTyped');
      if (o.constValueScalar) {
        bump('strScalarForm');
        continue;
      }
      if (flat.length < 4) {
        bump('strNeither');
        continue;
      }
      final declared = ByteData.sublistView(flat).getUint32(0);
      if (declared == 0 && flat.length == 5 && flat[4] == 0) {
        bump('strEmptyPad');
        continue;
      }
      if (4 + declared != flat.length) {
        bump('strNeither');
        continue;
      }
      bump('strFits');
      final text = o.constText;
      if (text == null || text.isEmpty) continue;
      bump(text.codeUnits.every((code) => code >= 0x20 && code < 0x7f) ? 'strPrintable' : 'strNonPrintable');
      if (!text.contains('\n') && !text.contains('\r')) continue;
      bump('strMultiLine');
      final box = d.children(o.oid).firstWhere((g) => g.absBounds != null, orElse: () => o).absBounds;
      // A one-line constant box is 19-21 px tall corpus-wide, so a box past
      // two of those is text LabVIEW laid out over several lines — geometry
      // no single-line reading of the payload can produce.
      if (box != null) bump(box.height >= 42 ? 'strMultiLineTallBox' : 'strMultiLineShortBox');
    }
  }
  return c;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('loop terminal census (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  test('structure-terminal glyph + constant-endpoint corpus census', () async {
    final merged = <String, int>{};
    for (final c in await corpusParallel(all, _census)) {
      c.forEach((k, v) => merged[k] = (merged[k] ?? 0) + v);
    }
    expectCorpusSnapshot('structure_terminals', merged);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('crc8: N feeders resolve to their constant boxes; hidden i glyphs decode', () {
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    if (!corpusOrSkip(crc8, what: 'crc8 snippet')) return;
    final d = buildViModel(extractSnippetVi(crc8.readAsBytesSync())!).blockDiagrams.single;

    // Terminal glyph visibility, straight from LabVIEW's own raster in the
    // snippet: the four for loops (oids 86/164/571/3042) all draw `N`; only
    // 86 and 3042 draw `i` (the others' unwired iteration terminals are
    // hidden). Terminal carrier oid -> (dco oid, hidden, raw DCO objFlags):
    // the raw flag words pin the hidden-vs-shown `i` pair as differing in
    // kTerminalGlyphHiddenFlag alone (0x820140 vs 0x020140).
    const glyphs = {
      119: (118, false, 0x020140), // i, "Create CRC-8 LUT" loop 86 — drawn
      194: (193, true, 0x820140), //  i, inner 8-bit loop 164 — absent
      605: (604, true, 0x820140), //  i, "Calculate CRC-8" loop 571 — absent
      3063: (3062, false, 0x020140), // i, disabled LUT loop 3042 — drawn
      89: (91, false, 0x020000), //   N, loop 86 — fed by the "bytes" 256 box
      167: (169, false, 0x020000), // N, loop 164 — fed by the "8-bits" 8 box
      574: (576, false, 0x020000), // N, loop 571 — drawn bare (count unwired)
      3045: (3047, false, 0x020000), // N, loop 3042 — fed by a 256 box
    };
    glyphs.forEach((oid, want) {
      final dco = d.terminalDco(oid);
      expect(dco?.oid, want.$1, reason: 'terminal $oid DCO');
      expect(d.terminalGlyphHidden(oid), want.$2, reason: 'terminal $oid hidden');
      expect(dco?.objFlags, want.$3, reason: 'terminal $oid DCO objFlags');
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

    // Each feeder wire ships an exact closed two-point polyline from its
    // constant shell's centre to the loop's N terminal attach rect.
    const routes = {
      399: [(x: 122, y: 383), (x: 166, y: 383)], // 256 -> loop 86 N
      375: [(x: 232, y: 441), (x: 271, y: 441)], // 8 -> loop 164 N
      3126: [(x: 201, y: 206), (x: 230, y: 206)], // 256 -> loop 3042 N
    };
    final matched = <int>{};
    for (final w in d.wires) {
      final want = routes[w.signalOid];
      if (want == null) continue;
      matched.add(w.signalOid);
      expect(w.routePoints, want, reason: 'signal ${w.signalOid}');
    }
    // Guard against the loop vacuously passing zero assertions.
    expect(matched, routes.keys.toSet(), reason: 'all three feeder signals present');

    // The three-endpoint thick LUT wire ships at the closed tier from its
    // array constant's ELEMENT centre ([ViDiagram.
    // endpointConstantElementBounds]) — the closure-arbitrated attach — with
    // both branch leaves landing exactly on the 571/716 tunnel attach rects.
    final lut = d.wires.singleWhere((w) => w.signalOid == 879);
    expect(lut.routeTreeFidelity, WireRouteFidelity.closed, reason: 'LUT wire tier');
    expect(lut.routeTree!.polylines, [
      [(x: 483, y: 178), (x: 512, y: 178), (x: 512, y: 267), (x: 524, y: 267)],
      [(x: 512, y: 178), (x: 842, y: 178), (x: 842, y: 305), (x: 861, y: 305)],
    ], reason: 'LUT wire runs');
    expect(lut.routeTree!.junctions, [(x: 512, y: 178)], reason: 'LUT junction');
  });
}
