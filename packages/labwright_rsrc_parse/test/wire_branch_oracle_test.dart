@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'wire_style_oracle.dart';

Map<String, int> _census(Uint8List png, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final Raster raster;
  try {
    raster = decodePngRaster(png);
  } catch (_) {
    return c;
  }
  final vi = extractSnippetVi(png);
  if (vi == null) return c;
  final interior = snippetDiagramInterior(raster.width, raster.height);
  final model = buildViModelFromDecoded(decodeSections(vi));
  if (model.blockDiagrams.isEmpty) return c;
  var bi = 0;
  for (var i = 1; i < model.blockDiagrams.length; i++) {
    if (model.blockDiagrams[i].objects.length > model.blockDiagrams[bi].objects.length) bi = i;
  }
  final bd = model.blockDiagrams[bi];
  final reg = registerDiagram(bd, raster, interior);
  if (reg.max < 150 || reg.score / reg.max < (reg.leafMode ? 0.60 : 0.75)) {
    bump('brc_reg_failed');
    return c;
  }
  bump('brc_reg_ok');

  bool onInk(ViPoint p) {
    final px = p.x - reg.dx + interior.left, py = p.y - reg.dy + interior.top;
    for (var oy = -1; oy <= 1; oy++) {
      for (var ox = -1; ox <= 1; ox++) {
        final x = px + ox, y = py + oy;
        if (x < interior.left || x >= interior.right || y < interior.top || y >= interior.bottom) continue;
        final o = (y * raster.width + x) * 4;
        if (raster.rgba[o] <= 210 || raster.rgba[o + 1] <= 210 || raster.rgba[o + 2] <= 210) return true;
      }
    }
    return false;
  }

  for (final w in bd.wires) {
    if (w.endpointOids.length < 3) continue;
    final branch = w.branchRoute;
    if (branch == null) continue;
    if (!objectVisibleInRender(bd, w.signalOid)) continue;
    final closed = w.routeTree != null && w.routeTreeFidelity == WireRouteFidelity.closed;
    final ViWireRouteTree tree;
    if (closed) {
      tree = w.routeTree!;
    } else {
      final origin = bd.wireAttachPoint(w.endpointOids[0]);
      if (origin == null) continue;
      tree = walkWireBranchRoute(branch, origin);
    }
    final scope = closed ? 'shipped' : 'walk';
    bump('brc_${scope}_wires');
    for (final line in tree.polylines) {
      for (var s = 0; s < line.length - 1; s++) {
        final a = line[s], b = line[s + 1];
        final steps = (a.x - b.x).abs() + (a.y - b.y).abs();
        for (var t = 0; t <= steps; t++) {
          final den = steps == 0 ? 1 : steps;
          final p = (x: a.x + (b.x - a.x) * t ~/ den, y: a.y + (b.y - a.y) * t ~/ den);
          bump('brc_${scope}_runpx');
          if (onInk(p)) bump('brc_${scope}_runink');
        }
      }
    }
    for (final j in tree.junctions) {
      bump('brc_${scope}_junctions');
      if (onInk(j)) bump('brc_${scope}_junc_on_ink');
    }
  }
  return c;
}

const kJunctionsOffInk = <String, int>{
  '13430104_BZazZ.png': 1,
  '31949337_Nurez.png': 1,
  '50799360_sx9Q3.png': 1,
  '55094384_3wrOI.png': 1,
  'Creating_an_Intensity_Graph_from_a_Single_Waveform.png': 1,
  'Dragging_Individual_Curves_Up_and_Down_in_LabVIEW_Waveform_Graph.png': 2,
};

const kShippedRunInkPct = <String, int>{
  '13430104_BZazZ.png': 51,
  '23663209_uRs90.png': 97,
  '31949337_Nurez.png': 12,
  '33003667_WQUOg.png': 96,
  '34140795_eK3nc.png': 91,
  '42048253_DiRsZ.png': 97,
  '42048253_fqcSl.png': 98,
  '44094992_MM1he.png': 98,
  '50799360_sx9Q3.png': 13,
  '55094384_3wrOI.png': 98,
  '55184810_goINc.png': 98,
  '73343310_s8oxG.png': 97,
  '74131160_O8ioW.png': 56,
  '75016950_8iSWg.png': 91,
  'Creating_an_Intensity_Graph_from_a_Single_Waveform.png': 95,
  'Dragging_Individual_Curves_Up_and_Down_in_LabVIEW_Waveform_Graph.png': 26,
  'Export Palette Image WMF.png': 97,
  'Get_Multiple_Inspection_Images_with_The_Vision_Builder_for_Automated_I.png': 97,
  'How_Can_I_Address_Multiple_Nodes_with_NI_Industrial_Communications_for.png': 98,
  'How_Do_I_Click_the_Mouse_Programmatically_in_LabVIEW.png': 96,
  'How_to_Programmatically_Acquire_a_Full_Screenshot_in_LabVIEW_2.png': 93,
  'Perform_DAQmx_Device_Reset_or_Self_Test_Programmatically.png': 98,
  'Programmatically_Set_Plot_Image_on_Several_Plot_Areas_of_a_Mixed_Signa_3.png': 89,
  'ProjectItems.png': 98,
  'Stopping_a_TestStand_Sequence_From_a_LabVIEW_UI.png': 96,
  'Symbols1Bit.png': 60,
};

void main() {
  final pngs = listSnippetPngs(corpusViDir);
  late final Map<String, Map<String, int>> byFile;
  setUpAll(() async {
    final res = await Future.wait([for (final f in pngs) Future(() => _census(f.readAsBytesSync(), f.path))]);
    byFile = {for (var i = 0; i < pngs.length; i++) pngs[i].uri.pathSegments.last: res[i]};
  });

  test('branch oracle law: shipped junction dots sit on reference ink', () {
    final offInk = <String, int>{};
    var junctions = 0;
    byFile.forEach((name, c) {
      final off = (c['brc_shipped_junctions'] ?? 0) - (c['brc_shipped_junc_on_ink'] ?? 0);
      junctions += c['brc_shipped_junctions'] ?? 0;
      if (off > 0) offInk[name] = off;
    });
    expect(junctions, greaterThan(0), reason: 'the registrable snippet corpus contains shipped branching trees');
    expect(offInk, kJunctionsOffInk);
  });

  test('branch oracle law: shipped interior geometry overlays reference ink', () {
    final below = <String, int>{};
    byFile.forEach((name, c) {
      final px = c['brc_shipped_runpx'] ?? 0;
      if (px == 0) return;
      final pct = 100 * (c['brc_shipped_runink'] ?? 0) ~/ px;
      if (pct < (kShippedRunInkPct[name] ?? 99)) below[name] = pct;
    });
    expect(below, isEmpty);
  });
}
