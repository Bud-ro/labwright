@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';
import 'test_util.dart';

int? _flatWidth(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

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
